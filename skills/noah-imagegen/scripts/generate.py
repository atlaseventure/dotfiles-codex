#!/usr/bin/env python3
"""通过 Noah 的 Images API 生成一张图片。"""

import sys

from image_api import main


if __name__ == "__main__":
    sys.exit(main("generate"))
