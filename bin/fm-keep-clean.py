#!/usr/bin/env python3
"""Keep-clean policy and private ideas list.

Usage: fm-keep-clean.py check-spawn PROJECT --home HOME
       fm-keep-clean.py check-pr < snapshot.json
       fm-keep-clean.py sort PROJECT --home HOME [--done]
       fm-keep-clean.py idea PROJECT TITLE --home HOME [--replaces ID]
       fm-keep-clean.py ideas PROJECT --home HOME

All open GitHub PRs count toward the five-PR budget; never close them here.
A fresh ship is refused at five; CI refuses a PR ranked after fifth
by creation time, then number. Non-GitHub projects are outside this policy.
Projects require a completed local sort each UTC Monday.
Open PRs expire after 14 days and block sorting completion and admission
until a human merges or closes them; this tool never closes work.
Ideas are private JSON records in HOME/data/keep-clean/OWNER/REPO.json, expire
after 14 days, and carry an explicit replaces field (null means no replacement).
sort --done records review without changing jobs.
check-pr consumes {pulls, number}; pulls use GitHub REST PR fields.
All API reads use gh-axi with full base64 output to avoid TOON truncation.
"""

import argparse
import base64
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def now():
    return dt.datetime.now(dt.timezone.utc)


def api(path):
    result = subprocess.run(
        ["gh-axi", "api", path, "--jq", "@base64", "--full"],
        check=True, text=True, capture_output=True, timeout=60,
    )
    match = re.search(r"^  body: ([A-Za-z0-9+/=]+)$", result.stdout, re.M)
    if not match:
        raise ValueError("gh-axi returned no complete base64 body")
    return json.loads(base64.b64decode(match[1], validate=True))


def repository(project):
    result = subprocess.run(
        ["git", "-C", project, "remote", "get-url", "origin"],
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        return None
    match = re.fullmatch(
        r"(?:git@github\.com:|https://github\.com/|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?",
        result.stdout.strip(),
    )
    return match[1] if match else None


def snapshot(repo):
    pulls = []
    page = 1
    while True:
        batch = api(f"/repos/{repo}/pulls?state=open&per_page=100&page={page}")
        if not isinstance(batch, list):
            raise ValueError("pulls response must be a list")
        pulls.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return pulls


def counted(pulls):
    return sorted(pulls, key=lambda p: (p["created_at"], p["number"]))


def require_disposition(pulls):
    cutoff = now() - dt.timedelta(days=14)
    expired = [str(p["number"]) for p in pulls
               if dt.datetime.fromisoformat(p["created_at"].replace("Z", "+00:00")) <= cutoff]
    if expired:
        raise ValueError("Expired PRs require disposition (merge or close): " + ", ".join(expired))


def load_record(path):
    return json.loads(path.read_text()) if path.exists() else {"ideas": [], "sorted_week": None}


def save_record(path, record):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".keep-clean-")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(record, output, indent=2)
            output.write("\n")
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check-pr")
    for command in ("check-spawn", "sort", "idea", "ideas"):
        child = sub.add_parser(command)
        child.add_argument("project")
        child.add_argument("--home", required=True)
        if command == "sort":
            child.add_argument("--done", action="store_true")
        if command == "idea":
            child.add_argument("title")
            child.add_argument("--replaces", default=None)
    args = parser.parse_args()
    if args.command == "check-pr":
        data = json.load(sys.stdin)
        require_disposition(data["pulls"])
        ranked = counted(data["pulls"])
        if data["number"] in [p["number"] for p in ranked[5:]]:
            raise ValueError("PR limit exceeded: sort existing work before opening another PR")
        print("PR limit passed")
        return
    repo = repository(args.project)
    if repo is None:
        if args.command == "check-spawn":
            return
        raise ValueError("keep-clean requires a GitHub origin")
    path = Path(args.home) / "data" / "keep-clean" / (repo + ".json")
    record = load_record(path)
    today = now().date()
    monday = (today - dt.timedelta(days=today.weekday())).isoformat()
    if args.command == "idea":
        record["ideas"].append({"title": args.title, "created": today.isoformat(),
                                "expires": (today + dt.timedelta(days=14)).isoformat(),
                                "replaces": args.replaces})
        save_record(path, record)
        print("Idea saved with 14-day expiry and replaces field")
        return
    if args.command == "ideas":
        for idea in record["ideas"]:
            state = "expired" if idea["expires"] <= today.isoformat() else "live"
            print(f"{state}: {json.dumps(idea)}")
        return
    pulls = snapshot(repo)
    if args.command == "sort":
        for pull in pulls:
            created = dt.datetime.fromisoformat(pull["created_at"].replace("Z", "+00:00"))
            age = (now() - created).days
            print(f'{pull["html_url"]} age={age} days {"EXPIRED: disposition required" if age >= 14 else ""}')
        for idea in record["ideas"]:
            print(f'{"EXPIRED" if idea["expires"] <= today.isoformat() else "idea"}: {json.dumps(idea)}')
        if args.done:
            require_disposition(pulls)
            record["sorted_week"] = monday
            save_record(path, record)
            print(f"Monday sort recorded for {monday}")
        return
    require_disposition(pulls)
    if record["sorted_week"] != monday:
        raise ValueError("Monday sort due: run sort, review expiry flags, then sort --done")
    if len(counted(pulls)) >= 5:
        raise ValueError("project has 5 or more open PRs; save the work as an idea")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print(f"keep-clean: {error}", file=sys.stderr)
        sys.exit(1)
