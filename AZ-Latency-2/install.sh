#!/bin/bash
set -e

# cffi/cryptography/PyNaCl may build from source (e.g. on Python versions
# without prebuilt wheels). That requires a C compiler, the matching Python
# development headers (Python.h), and libffi headers.
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y build-essential libffi-dev "python${PY_VER}-dev" \
        || sudo apt-get install -y build-essential libffi-dev python3-dev
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y gcc libffi-devel "python${PY_VER}-devel" \
        || sudo dnf install -y gcc libffi-devel python3-devel
elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y gcc libffi-devel "python${PY_VER}-devel" \
        || sudo yum install -y gcc libffi-devel python3-devel
fi

python3 -m pip install --upgrade pip
pip install -r requirements.txt