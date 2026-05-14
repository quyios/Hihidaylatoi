#!/usr/bin/env python3

print("Running script version V26.0")

import subprocess
import time
import random
import string
import sys
import requests
import signal
from datetime import datetime


PORT = 1080

TG_BOT_TOKEN = "YOUR_BOT_TOKEN"
TG_CHAT_ID = "YOUR_CHAT_ID"

API_BASE = f"https://api.telegram.org/bot{TG_BOT_TOKEN}"


# =========================================================
# ZONES
# =========================================================

# TOKYO
TOKYO_ZONES = [
    "asia-northeast1-a",
    "asia-northeast1-b",
    "asia-northeast1-c"
]

# OSAKA
OSAKA_ZONES = [
    "asia-northeast2-a",
    "asia-northeast2-b",
    "asia-northeast2-c"
]

# KOREA
KOREA_ZONES = [
    "asia-northeast3-a",
    "asia-northeast3-b",
    "asia-northeast3-c"
]


# =========================================================
# TOTAL TARGET
# =========================================================

TOTAL_TOKYO = 6
TOTAL_OSAKA = 6
TOTAL_KOREA = 12

TOTAL_PROXY = TOTAL_TOKYO + TOTAL_OSAKA + TOTAL_KOREA

# 1 PROJECT ≈ 8 VM
PROJECT_LIMIT = 3


STOP_REQUEST = False


# =========================================================
# CTRL + C
# =========================================================

def handle_ctrlc(sig, frame):

    global STOP_REQUEST

    if not STOP_REQUEST:
        print("\nStopping VM creation...")
        STOP_REQUEST = True
    else:
        print("\nForce exit")
        sys.exit(0)


signal.signal(signal.SIGINT, handle_ctrlc)


# =========================================================
# RUN COMMAND
# =========================================================

def run(cmd):

    p = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    return p.returncode, p.stdout.strip(), p.stderr.strip()


# =========================================================
# REGION NAME
# =========================================================

def region_from_zone(zones):

    if not zones:
        return "unknown"

    return zones[0].rsplit("-", 1)[0]


TOKYO_REGION = region_from_zone(TOKYO_ZONES)
OSAKA_REGION = region_from_zone(OSAKA_ZONES)
KOREA_REGION = region_from_zone(KOREA_ZONES)


# =========================================================
# BILLING
# =========================================================

def get_billing_accounts():

    code, out, err = run([
        "gcloud",
        "billing",
        "accounts",
        "list",
        "--format=value(name,displayName)"
    ])

    if not out:
        print("No billing accounts found")
        sys.exit()

    result = []

    for line in out.splitlines():

        parts = line.split()

        billing_id = parts[0].split("/")[-1]

        name = " ".join(parts[1:])

        result.append((billing_id, name))

    return result


def select_billing():

    billings = get_billing_accounts()

    print("\n===== CHỌN BILLING =====\n")

    for i, b in enumerate(billings):
        print(f"{i+1} - {b[1]} ({b[0]})")

    choice = input("\nChọn billing: ").strip()

    if not choice.isdigit():
        sys.exit()

    idx = int(choice) - 1

    if idx < 0 or idx >= len(billings):
        sys.exit()

    billing = billings[idx][0]

    print(f"\nBilling selected: {billing}")

    return billing


# =========================================================
# PROJECT
# =========================================================

def get_projects_from_billing(billing):

    code, out, err = run([
        "gcloud",
        "beta",
        "billing",
        "projects",
        "list",
        f"--billing-account={billing}",
        "--format=value(projectId)"
    ])

    if not out:
        print("No projects found")
        sys.exit()

    return out.splitlines()


def select_projects(all_projects):

    print("\n===== CHỌN PROJECT =====\n")
    print("1 - All Projects")
    print("2 - Chọn thủ công\n")

    choice = input("Lựa chọn: ").strip()

    if choice == "1":
        return all_projects

    if choice == "2":

        print()

        for i, p in enumerate(all_projects):
            print(f"{i+1} - {p}")

        raw = input("\nNhập số project (vd: 1,2,3): ")

        ids = [
            int(x.strip()) - 1
            for x in raw.split(",")
            if x.strip().isdigit()
        ]

        selected = []

        for i in ids:

            if 0 <= i < len(all_projects):
                selected.append(all_projects[i])

        if not selected:
            sys.exit()

        return selected

    sys.exit()


# =========================================================
# FIREWALL
# =========================================================

def ensure_firewall(project):

    code, out, err = run([
        "gcloud",
        "compute",
        "firewall-rules",
        "list",
        f"--project={project}",
        "--filter=name=allow-socks",
        "--format=value(name)"
    ])

    if out.strip():
        return

    run([
        "gcloud",
        "compute",
        "firewall-rules",
        "create",
        "allow-socks",
        f"--project={project}",
        "--allow=tcp:1080",
        "--direction=INGRESS",
        "--priority=1000",
        "--network=default"
    ])


# =========================================================
# ACCOUNT
# =========================================================

def get_account():

    code, out, err = run([
        "gcloud",
        "config",
        "get-value",
        "account"
    ])

    if out:
        return out

    return "unknown"


ACCOUNT_EMAIL = get_account()

OUTPUT_FILE = f"{ACCOUNT_EMAIL}.txt"

TODAY = datetime.now().strftime("%d/%m")


# =========================================================
# TELEGRAM
# =========================================================

def tg_send_file(filepath, caption):

    try:

        with open(filepath, "rb") as f:

            requests.post(
                f"{API_BASE}/sendDocument",
                data={
                    "chat_id": TG_CHAT_ID,
                    "caption": caption
                },
                files={
                    "document": f
                },
                timeout=30
            )

    except:
        pass


# =========================================================
# RANDOM
# =========================================================

def random_user_pass():

    user = "u" + "".join(
        random.choice(string.ascii_lowercase + string.digits)
        for _ in range(7)
    )

    pw = "".join(
        random.choice(string.ascii_letters + string.digits)
        for _ in range(10)
    )

    return user, pw


def random_vm():

    first = [
        "kenshiro",
        "raventon",
        "hartwell",
        "delvinar",
        "calderon",
        "trenwick",
        "marvello",
        "brenford",
        "alverton",
        "norvello"
    ]

    second = [
        "eto",
        "kor",
        "lex",
        "tor",
        "ziv",
        "nex",
        "var",
        "zen",
        "tal",
        "vex"
    ]

    number = random.randint(100, 999)

    return f"{random.choice(first)}-{random.choice(second)}{number}"


# =========================================================
# COUNT INSTANCE
# =========================================================

def count_instances(project, region):

    code, out, err = run([
        "gcloud",
        "compute",
        "instances",
        "list",
        f"--project={project}",
        "--format=value(zone)"
    ])

    count = 0

    for zone in out.splitlines():

        if region in zone:
            count += 1

    return count


def count_all_projects(projects):

    tokyo = 0
    osaka = 0
    korea = 0

    for project in projects:

        tokyo += count_instances(project, TOKYO_REGION)
        osaka += count_instances(project, OSAKA_REGION)
        korea += count_instances(project, KOREA_REGION)

    return tokyo, osaka, korea


# =========================================================
# DANTE
# =========================================================

def write_dante(user, pw):

    script = f"""#!/bin/bash

apt-get update -y
apt-get install -y dante-server

NIC=$(ip -o -4 route show to default | awk '{{print $5}}')

useradd -m {user}
echo "{user}:{pw}" | chpasswd

cat >/etc/danted.conf <<EOF

logoutput: syslog

internal: 0.0.0.0 port = {PORT}

external: $NIC

socksmethod: username

user.notprivileged: nobody

client pass {{
    from: 0.0.0.0/0 to: 0.0.0.0/0
}}

socks pass {{
    from: 0.0.0.0/0 to: 0.0.0.0/0
}}

EOF

systemctl restart danted
systemctl enable danted
"""

    with open("startup.sh", "w") as f:
        f.write(script)

    return "startup.sh"


# =========================================================
# GET IP
# =========================================================

def get_ip(project, zone, name):

    code, out, err = run([
        "gcloud",
        "compute",
        "instances",
        "describe",
        name,
        f"--project={project}",
        f"--zone={zone}",
        "--format=value(networkInterfaces[0].accessConfigs[0].natIP)"
    ])

    return out.strip()


# =========================================================
# CREATE VM
# =========================================================

def create_vm(project, zone, name, user, pw, status):

    status[0] = f"Creating VM {zone}"

    script = write_dante(user, pw)

    code, out, err = run([
        "gcloud",
        "compute",
        "instances",
        "create",
        name,
        f"--project={project}",
        f"--zone={zone}",
        "--machine-type=e2-micro",
        "--image-family=debian-11",
        "--image-project=debian-cloud",
        f"--metadata-from-file=startup-script={script}",
        "--tags=socks"
    ])

    return code == 0


# =========================================================
# TRY REGION
# =========================================================

def try_region(project, zones, status):

    name = random_vm()

    user, pw = random_user_pass()

    for zone in zones:

        ok = create_vm(
            project,
            zone,
            name,
            user,
            pw,
            status
        )

        if ok:

            time.sleep(8)

            ip = get_ip(project, zone, name)

            if ip:
                return f"{ip}:{PORT}:{user}:{pw}"

    return None


# =========================================================
# UI
# =========================================================

def draw_ui(done, total, tokyo, osaka, korea, status):

    percent = int((done / total) * 100) if total else 0

    bar_len = 32

    filled = int(bar_len * done / total) if total else 0

    bar = "█" * filled + "░" * (bar_len - filled)

    sys.stdout.write("\033[H\033[J")

    print("Tiến trình tạo Proxy ....\n")

    print(f"[{bar}]")

    print(f"\n{percent}%\n")

    print(f"Created: {done} / {total}")

    print(f"{TOKYO_REGION} : {tokyo} / {TOTAL_TOKYO}")

    print(f"{OSAKA_REGION} : {osaka} / {TOTAL_OSAKA}")

    print(f"{KOREA_REGION} : {korea} / {TOTAL_KOREA}\n")

    print(f"Status: {status[0]}")


# =========================================================
# MAIN
# =========================================================

def main():

    billing = select_billing()

    all_projects = get_projects_from_billing(billing)[:PROJECT_LIMIT]

    projects = select_projects(all_projects)

    proxies = []

    status = ["Starting"]

    while len(proxies) < TOTAL_PROXY and not STOP_REQUEST:

        tokyo_total, osaka_total, korea_total = count_all_projects(projects)

        draw_ui(
            len(proxies),
            TOTAL_PROXY,
            tokyo_total,
            osaka_total,
            korea_total,
            status
        )

        for project in projects:

            if STOP_REQUEST:
                break

            ensure_firewall(project)

            # TOKYO
            if tokyo_total < TOTAL_TOKYO:

                status[0] = f"Creating TOKYO ({project})"

                proxy = try_region(
                    project,
                    TOKYO_ZONES,
                    status
                )

                if proxy:

                    proxies.append(proxy)

                    tokyo_total += 1

            # OSAKA
            if osaka_total < TOTAL_OSAKA:

                status[0] = f"Creating OSAKA ({project})"

                proxy = try_region(
                    project,
                    OSAKA_ZONES,
                    status
                )

                if proxy:

                    proxies.append(proxy)

                    osaka_total += 1

            # KOREA
            if korea_total < TOTAL_KOREA:

                status[0] = f"Creating KOREA ({project})"

                proxy = try_region(
                    project,
                    KOREA_ZONES,
                    status
                )

                if proxy:

                    proxies.append(proxy)

                    korea_total += 1

            if len(proxies) >= TOTAL_PROXY:
                break

            time.sleep(0.5)

    print("\nExporting proxy...\n")

    with open(OUTPUT_FILE, "w") as f:

        f.write(f"Tổng Số Proxy : {len(proxies)}\n\n")

        f.write(f"{TODAY}---- {ACCOUNT_EMAIL}--\n")

        for p in proxies:
            f.write(p + "\n")

    tg_send_file(
        OUTPUT_FILE,
        f"{len(proxies)} Proxy đã được tạo"
    )

    print("\nDone")


if __name__ == "__main__":
    main()
