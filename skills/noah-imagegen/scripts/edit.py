#!/usr/bin/env python3
"""通过 Noah 的 Images API 编辑一张图片，支持多图输入和可选蒙版。"""

import sys

from image_api import main


if __name__ == "__main__":
    sys.exit(main("edit"))
