#!/bin/sh
# Railway 会注入 $PORT 环境变量（动态端口），这里替换进配置
PORT_TO_USE="${PORT:-8080}"
if [ -z "$UUID" ]; then
  echo "ERROR: 请在 Railway Variables 里设置 UUID" >&2
  exit 1
fi
sed -i "s/__PORT__/${PORT_TO_USE}/g; s/__UUID__/${UUID}/g" config.json
exec ./xray run -c config.json
