FROM postgres:16-alpine

# Install cron
RUN apk add --no-cache busybox-suid

# Copy script backup
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

# Setup cron job (Jalan setiap hari jam 02:00 AM)
RUN echo "0 2 * * * /usr/local/bin/backup.sh >> /var/log/cron.log 2>&1" > /etc/crontabs/root

# Buat log file
RUN touch /var/log/cron.log

# Jalankan cron di foreground
CMD ["crond", "-f", "-l", "8"]
