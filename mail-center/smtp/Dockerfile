FROM alpine:3.23
RUN apk add --no-cache postfix ca-certificates
COPY entrypoint.sh /usr/local/bin/mail-smtp
RUN chmod 755 /usr/local/bin/mail-smtp
EXPOSE 25
CMD ["/usr/local/bin/mail-smtp"]
