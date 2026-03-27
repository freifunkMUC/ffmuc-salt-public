#!/usr/bin/env python3
"""Convert GeoLite2 mmdb databases to HAProxy map files."""

import maxminddb
import ipaddress
import sys
import os

GEOIP_DIR = "/etc/haproxy/geoip"
MAP_DIR = "/etc/haproxy/maps"


def generate_maps():
    city_db_path = os.path.join(GEOIP_DIR, "GeoLite2-City.mmdb")
    asn_db_path = os.path.join(GEOIP_DIR, "GeoLite2-ASN.mmdb")

    country_map = {}
    city_map = {}
    provider_map = {}
    asn_map = {}

    # Process City database for country and city
    if os.path.exists(city_db_path):
        with maxminddb.open_database(city_db_path) as db:
            # Iterate all networks in the database
            for network, record in db:
                if record is None:
                    continue
                net_str = str(network)

                country = None
                c = record.get("country") or record.get("registered_country")
                if c and c.get("names"):
                    country = c["names"].get("en")
                if not country and c:
                    country = c.get("iso_code")
                if country:
                    country_map[net_str] = country

                city_name = None
                if record.get("city") and record["city"].get("names"):
                    city_name = record["city"]["names"].get("en")
                if city_name:
                    city_map[net_str] = city_name

    # Process ASN database for provider
    if os.path.exists(asn_db_path):
        with maxminddb.open_database(asn_db_path) as db:
            for network, record in db:
                if record is None:
                    continue
                org = record.get("autonomous_system_organization")
                if org:
                    provider_map[str(network)] = org
                asn = record.get("autonomous_system_number")
                if asn:
                    asn_map[str(network)] = str(asn)

    # Write map files
    write_map(os.path.join(MAP_DIR, "geoip_country.map"), country_map)
    write_map(os.path.join(MAP_DIR, "geoip_city.map"), city_map)
    write_map(os.path.join(MAP_DIR, "geoip_provider.map"), provider_map)
    write_map(os.path.join(MAP_DIR, "geoip_asn.map"), asn_map)

    print(
        f"Generated maps: country={len(country_map)} city={len(city_map)} provider={len(provider_map)} asn={len(asn_map)}"
    )


def write_map(path, data):
    with open(path, "w") as f:
        for network, value in sorted(data.items()):
            # Escape spaces for HAProxy map format
            f.write(f"{network} {value}\n")


if __name__ == "__main__":
    generate_maps()
