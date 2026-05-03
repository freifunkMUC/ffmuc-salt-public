#!/usr/bin/env python3

import itertools
import logging
import subprocess

import netifaces as netif

log = logging.getLogger(__name__)


def call(cmdnargs):
    try:
        output = subprocess.check_output(cmdnargs, stderr=None)
        return [line.decode("utf-8") for line in output.splitlines()]
    except subprocess.CalledProcessError as err:
        log.warning("command failed: %s: %s", cmdnargs, err)
    except Exception as err:
        log.warning("command error: %s: %s", cmdnargs, err)
    return []


def merge(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        d = dict(a)
        d.update({k: merge(a.get(k, None), b[k]) for k in b})
        return d

    if isinstance(a, list) and isinstance(b, list):
        return [merge(x, y) for x, y in itertools.zip_longest(a, b)]

    return a if b is None else b


def getInterfaceMAC(interface):
    try:
        addresses = netif.ifaddresses(interface)
        return addresses[netif.AF_LINK][0]["addr"]
    except (ValueError, KeyError, IndexError):
        return None
