#!/usr/bin/env python3
"""Transfer a departing user's Google Workspace data to their delegate.

Run BEFORE the user is suspended/deleted. Needs a service account with
domain-wide delegation granted these scopes in the Admin console:
  https://www.googleapis.com/auth/admin.directory.user.readonly
  https://www.googleapis.com/auth/admin.datatransfer
  https://www.googleapis.com/auth/gmail.settings.sharing   (Gmail delegation only)

Gmail has no transfer API: this grants the delegate mailbox access (delegation).
"""
import argparse
import sys
import time

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

ADMIN_SCOPES = [
    "https://www.googleapis.com/auth/admin.directory.user.readonly",
    "https://www.googleapis.com/auth/admin.datatransfer",
]
GMAIL_SCOPES = ["https://www.googleapis.com/auth/gmail.settings.sharing"]


def creds(key_file, scopes, subject):
    return service_account.Credentials.from_service_account_file(
        key_file, scopes=scopes, subject=subject
    )


def get_user(directory, email):
    return directory.users().get(userKey=email, fields="id,primaryEmail,suspended").execute()


def list_applications(transfer):
    apps, token = [], None
    while True:
        resp = transfer.applications().list(pageToken=token).execute()
        apps += resp.get("applications", [])
        token = resp.get("nextPageToken")
        if not token:
            return apps


def build_app_transfers(apps, only_apps=None):
    entries = []
    for app in apps:
        if only_apps and app.get("name", "").lower() not in only_apps:
            continue
        keys = {p["key"] for p in app.get("transferParams", [])}
        params = []
        if "PRIVACY_LEVEL" in keys:  # Drive & Docs: shared + private files
            params.append({"key": "PRIVACY_LEVEL", "value": ["SHARED", "PRIVATE"]})
        if "RELEASE_RESOURCES" in keys:  # Calendar: release booked rooms/resources
            params.append({"key": "RELEASE_RESOURCES", "value": ["TRUE"]})
        entry = {"applicationId": app["id"]}
        if params:
            entry["applicationTransferParams"] = params
        entries.append(entry)
        print(f"  - {app.get('name')} (id {app['id']}) params={[p['key'] for p in params]}")
    return entries


def run_transfer(transfer, old_id, new_id, entries, timeout, poll_seconds):
    body = {
        "oldOwnerUserId": old_id,
        "newOwnerUserId": new_id,
        "applicationDataTransfers": entries,
    }
    tid = transfer.transfers().insert(body=body).execute()["id"]
    print(f"Transfer {tid} started")
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = transfer.transfers().get(dataTransferId=tid).execute()
        code = status.get("overallTransferStatusCode", "").lower()
        print(f"  status: {code}")
        if code == "completed":
            return True
        if code == "failed":
            print(f"Transfer failed: {status}", file=sys.stderr)
            return False
        time.sleep(poll_seconds)
    print("Timed out waiting for transfer; it may still be running.", file=sys.stderr)
    return False


def add_gmail_delegate(key_file, owner, delegate):
    """Mailbox delegation. Must run while the owner is still ACTIVE (not suspended)."""
    gmail = build("gmail", "v1", credentials=creds(key_file, GMAIL_SCOPES, owner), cache_discovery=False)
    try:
        gmail.users().settings().delegates().create(
            userId="me", body={"delegateEmail": delegate}
        ).execute()
        print(f"Gmail delegation: {delegate} can now access {owner}")
    except HttpError as e:
        if e.resp.status == 409:
            print("Gmail delegation already exists")
        else:
            raise


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--owner", required=True, help="departing user's email")
    p.add_argument("--delegate", required=True, help="recipient email (from `terraform output offboarding_delegates`)")
    p.add_argument("--sa-key", required=True, help="service account JSON key file")
    p.add_argument("--admin", required=True, help="Workspace admin to impersonate")
    p.add_argument("--timeout", type=int, default=3600, help="max seconds to wait for the transfer")
    p.add_argument("--poll-seconds", type=int, default=30, help="status polling interval")
    p.add_argument(
        "--only-apps",
        default="",
        help="comma-separated Google application names to transfer (default: every transferable app)",
    )
    p.add_argument("--skip-gmail-delegate", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()

    owner, delegate = a.owner.lower(), a.delegate.lower()
    if owner == delegate:
        sys.exit("owner and delegate are the same")

    admin = creds(a.sa_key, ADMIN_SCOPES, a.admin)
    directory = build("admin", "directory_v1", credentials=admin, cache_discovery=False)
    transfer = build("admin", "datatransfer_v1", credentials=admin, cache_discovery=False)

    old, new = get_user(directory, owner), get_user(directory, delegate)
    if new.get("suspended"):
        sys.exit(f"delegate {delegate} is suspended; pick another delegate")

    print(f"Transferring {owner} -> {delegate}")
    only = {n.strip().lower() for n in a.only_apps.split(",") if n.strip()} or None
    entries = build_app_transfers(list_applications(transfer), only)
    if not entries:
        sys.exit("no applications selected for transfer; check --only-apps")
    if a.dry_run:
        print("Dry run: nothing changed.")
        return

    ok = run_transfer(transfer, old["id"], new["id"], entries, a.timeout, a.poll_seconds)
    if not a.skip_gmail_delegate:
        add_gmail_delegate(a.sa_key, owner, delegate)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
