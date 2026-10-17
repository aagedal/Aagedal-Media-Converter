#!/usr/bin/env python3
"""Open an appcast-only PR from an isolated checkout after release publication."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location(
    "prepare_appcast", Path(__file__).with_name("prepare-release-appcast.py")
)
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


def update_feed(feed, item_xml, archive, info_plist):
    """Validate inputs, preserve existing releases, and accept identical retries."""
    item = ET.fromstring(item_xml)
    version_tag = f"{{{appcast.SPARKLE}}}version"
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / "source.xml"
        candidate = Path(temporary) / "candidate.xml"
        # Validate the release against the exported artifact even on a retry.
        source.write_text("<rss><channel></channel></rss>")
        appcast.prepare(source, candidate, item_xml, archive, info_plist)
        for previous in ET.parse(feed).findall("channel/item"):
            if previous.findtext(version_tag) == item.findtext(version_tag):
                fields = ("version", "shortVersionString", "minimumSystemVersion")
                enclosure = previous.find("enclosure")
                if enclosure is None or any(previous.findtext(f"{{{appcast.SPARKLE}}}{key}") !=
                       item.findtext(f"{{{appcast.SPARKLE}}}{key}") for key in fields) or \
                        enclosure.attrib != item.find("enclosure").attrib:
                    raise ValueError("Existing appcast build describes a different release")
                return False
        appcast.prepare(feed, candidate, item_xml, archive, info_plist)
        feed.write_text(candidate.read_text())
    return True


def publish(repo, item_path, archive, info_plist):
    item_xml = Path(item_path).read_text()
    item = ET.fromstring(item_xml)
    version = item.findtext(f"{{{appcast.SPARKLE}}}shortVersionString")
    build = item.findtext(f"{{{appcast.SPARKLE}}}version")
    branch = f"release/appcast-{version}-{build}"
    existing = json.loads(subprocess.check_output([
        "gh", "pr", "list", "--repo", repo, "--base", "main", "--head", branch,
        "--state", "open", "--json", "url",
    ], text=True))
    with tempfile.TemporaryDirectory(prefix="amc-appcast-") as temporary:
        checkout = Path(temporary) / "repo"
        subprocess.run([
            "gh", "repo", "clone", repo, str(checkout), "--", "--single-branch",
            "--branch", "main", "--filter=blob:none", "--no-checkout",
        ], check=True)

        def git(*args):
            subprocess.run(["git", "-C", str(checkout), *args], check=True)

        # No need to download the app's large bundled binaries to update its feed.
        git("sparse-checkout", "set", "--no-cone", "/appcast.xml")
        git("checkout", "main")
        main_feed = Path(temporary) / "main-appcast.xml"
        main_feed.write_text((checkout / "appcast.xml").read_text())
        if not update_feed(main_feed, item_xml, archive, info_plist):
            print(f"Appcast {version} ({build}) is already on main.")
            print("Confirm the Publish website appcast workflow succeeded.")
            return

        # A prior run may have pushed successfully but failed to create its PR.
        remote_branch = subprocess.run([
            "git", "-C", str(checkout), "ls-remote", "--exit-code", "--heads",
            "origin", f"refs/heads/{branch}",
        ], stdout=subprocess.DEVNULL, check=False)
        if remote_branch.returncode not in (0, 2):
            raise subprocess.CalledProcessError(remote_branch.returncode, remote_branch.args)
        if remote_branch.returncode == 0:
            git("fetch", "origin", f"{branch}:refs/remotes/origin/{branch}")
            git("checkout", "-b", branch, f"origin/{branch}")
            git("merge", "--no-edit", "origin/main")
        else:
            git("checkout", "-b", branch)
        changed = update_feed(checkout / "appcast.xml", item_xml, archive, info_plist)
        if changed:
            git("add", "appcast.xml")
            git("commit", "-m", f"Updated appcast for {version}.")
        git("push", "origin", branch)
        if existing:
            url = existing[0]["url"]
        else:
            body = Path(temporary) / "body.md"
            body.write_text(
                f"Adds the verified Sparkle appcast entry for {version} (build {build}).\n\n"
                "Merging this PR triggers the website appcast deployment. The live feed "
                "remains unchanged until this PR is merged and deployment succeeds.\n\n"
                "The release pipeline verified the update signature and distribution bundle; "
                "the feed entry matches the exported app and archive size.\n"
            )
            url = subprocess.check_output([
                "gh", "pr", "create", "--repo", repo, "--base", "main", "--head", branch,
                "--title", f"Update appcast for {version}", "--body-file", str(body),
            ], text=True).strip()
        print(f"Appcast PR: {url}")
        print("NEXT STEP: Merge the appcast PR and confirm the Publish website appcast workflow succeeds.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "item", "archive", "info-plist"):
        parser.add_argument(f"--{name}", required=True)
    args = parser.parse_args()
    publish(args.repo, Path(args.item).resolve(), Path(args.archive).resolve(),
            Path(args.info_plist).resolve())


if __name__ == "__main__":
    main()
