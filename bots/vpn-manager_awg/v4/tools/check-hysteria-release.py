#!/usr/bin/env python3
"""Verify a real official release using the same checksum parser as the installer."""
import argparse
import configparser
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'vpn/hysteria2'))
from install_hysteria2 import verify_binary


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--arch',choices=['amd64','arm64'],help='verify another architecture without executing it')
    parser.add_argument('--execute',action='store_true',help='Linux only: run verified binary --help')
    args=parser.parse_args()
    config=configparser.ConfigParser(interpolation=None)
    config.read(ROOT/'silent.example.ini')
    version=config['hysteria2']['version']
    arch={'x86_64':'amd64','aarch64':'arm64','arm64':'arm64'}.get(platform.machine())
    detected=arch
    arch=args.arch or arch
    if not arch:raise ValueError('Unsupported architecture')
    if args.execute and arch!=detected:raise ValueError('--execute requires the host architecture')
    if args.execute and platform.system()!='Linux':raise ValueError('--execute is for Linux only')
    asset='hysteria-linux-'+arch
    base='https://github.com/HyNetworks/hysteria/releases/download/'+version+'/'
    with tempfile.TemporaryDirectory() as directory:
        binary=Path(directory)/asset
        urllib.request.urlretrieve(base+asset,binary)
        with urllib.request.urlopen(base+'hashes.txt',timeout=30) as response:hashes=response.read().decode()
        digest=verify_binary(binary,hashes,asset)
        print(version+' '+asset+' SHA256 verified: '+digest)
        if args.execute:
            binary.chmod(0o700)
            subprocess.run([str(binary),'--help'],check=True,stdout=subprocess.DEVNULL,timeout=15)
            print('Verified Linux binary --help: OK')


if __name__=='__main__':main()
