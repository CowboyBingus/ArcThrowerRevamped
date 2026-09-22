"""Package the addon with Bingus Shared Loader's builder.

Usage:
    python -B scripts/build.py --loader <path to BingusSharedLoader checkout>
                               [--output releases/Arc-Thrower-Revamped-v1.1.zip]
"""
import argparse
from pathlib import Path
import subprocess
import sys

NAME = "mods/cowboybingus/arc_thrower_auto"
GUID = "00f25f55-962e-42e7-96ed-cc1f17fac9c3"
DISPLAY_NAME = "Arc Thrower Revamped - v1.1"
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--loader", required=True,
                        help="path to a BingusSharedLoader checkout")
    parser.add_argument("--output", default=str(ROOT / "releases"
                                                / "Arc-Thrower-Revamped-v1.1.zip"))
    arguments = parser.parse_args()
    builder = Path(arguments.loader) / "scripts" / "build_addon.py"
    if not builder.exists():
        raise SystemExit("No builder at {}".format(builder))
    subprocess.check_call([sys.executable, "-B", str(ROOT / "check.py")])
    command = [sys.executable, "-B", str(builder),
               "--name", NAME,
               "--entry", str(ROOT / "src" / "arc_thrower_auto.lua"),
               "--guid", GUID,
               "--display-name", DISPLAY_NAME,
               "--output", arguments.output]
    print(" ".join(command))
    subprocess.check_call(command)
    subprocess.check_call([sys.executable, "-B", str(ROOT / "check.py"),
                           "--archive", arguments.output])


if __name__ == "__main__":
    main()
