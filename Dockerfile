FROM alpine:latest

RUN apk add --no-cache curl unzip && \
    curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip && \
    unzip /tmp/xray.zip -d /app && \
    rm /tmp/xray.zip && \
    chmod +x /app/xray

WORKDIR /app
COPY config.json entrypoint.sh ./
RUN chmod +x entrypoint.sh

CMD ["./entrypoint.sh"]
