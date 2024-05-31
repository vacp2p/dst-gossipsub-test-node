#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <minutes> <hours>"
    exit 1
fi

minutes="$1"
hours="$2"

cron_expression="$minutes $hours * * *"

cron_job_file="/etc/cron.d/my-cron-job"
echo -e "$cron_expression /node/main  > /proc/1/fd/1 2>&1 \n" > "$cron_job_file"

echo "Cron job file created at $cron_job_file"

env >> /etc/environment

crontab /etc/cron.d/my-cron-job

cron -f