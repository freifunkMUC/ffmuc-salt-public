#!/usr/bin/env python3

import argparse
import json
import logging
import sys

from lib.respondd_client import ResponddClient
import lib.helper

parser = argparse.ArgumentParser()

parser.add_argument(
    "-d", "--test", action="store_true", help="Test Output", required=False
)
parser.add_argument(
    "-v", "--verbose", action="store_true", help="Verbose Output", required=False
)
parser.add_argument(
    "-t", "--dry-run", action="store_true", help="Dry Run", required=False
)

args = parser.parse_args()
options = vars(args)

logging.basicConfig(
    format="%(levelname)s %(name)s: %(message)s",
    level=logging.DEBUG if options["verbose"] else logging.INFO,
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

config = {
    "bridge": "br-client",
    "batman": "bat0",
    "port": 1001,
    "addr": "ff05::2:1001",
    "caching": 5,
    "rate_limit": 30,
    "rate_limit_burst": 10,
}

try:
    with open("config.json", "r") as fh:
        config = lib.helper.merge(config, json.load(fh))
except IOError:
    log.warning("no config.json, using defaults")

if options["test"]:
    from lib.nodeinfo import Nodeinfo
    from lib.statistics import Statistics
    from lib.neighbours import Neighbours

    print(json.dumps(Nodeinfo(config).getStruct(), sort_keys=True, indent=4))
    print(json.dumps(Statistics(config).getStruct(), sort_keys=True, indent=4))
    print(json.dumps(Neighbours(config).getStruct(), sort_keys=True, indent=4))
    sys.exit(0)

config["verbose"] = options["verbose"]
config["dry_run"] = options["dry_run"]

extResponddClient = ResponddClient(config)
extResponddClient.start()
