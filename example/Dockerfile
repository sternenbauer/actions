FROM alpine:3.22.0
RUN apk --no-cache add ca-certificates tini libc6-compat
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["pwd"]
