FROM alpine:3.19
RUN apk --no-cache add tini
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["pwd"]
