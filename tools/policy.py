#!/usr/bin/env python3
"""Offline model of the recovered core branch, not an access-control implementation."""
from pathlib import Path
import argparse, json

def listed(mac, paths):
    for path in paths:
        try:
            with Path(path).open(encoding='ascii') as f:
                if any(line.rstrip('\n') == mac.lower() for line in f):
                    return True
        except (OSError, UnicodeError):
            continue
    return False

def decide(mac, browseable, paths):
    member = listed(mac, paths)
    return {'list_match': member, 'core_branch_allows': not browseable if member else browseable}

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mac');p.add_argument('--browseable', choices=['yes','no'], required=True)
    p.add_argument('--login-list', required=True);p.add_argument('--nonlogin-list', required=True)
    a = p.parse_args(); print(json.dumps(decide(a.mac, a.browseable == 'yes', [a.login_list, a.nonlogin_list])))
