FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    apache2 \
    python3 \
    python3-pip \
    python3-venv \
    supervisor \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN a2enmod rewrite headers proxy proxy_http

RUN python3 -m venv /opt/okta-agent-api/venv \
    && /opt/okta-agent-api/venv/bin/pip install --no-cache-dir flask anthropic requests

COPY docker/app.py /opt/okta-agent-api/app.py
COPY docker/index.html /var/www/okta-agent-site/index.html
COPY docker/vhost.conf /etc/apache2/sites-available/okta-agent-site.conf
COPY docker/supervisor.conf /etc/supervisor/conf.d/okta-agent.conf

RUN a2dissite 000-default && a2ensite okta-agent-site

RUN chown -R www-data:www-data /var/www/okta-agent-site \
    && chown -R www-data:www-data /opt/okta-agent-api

EXPOSE 80

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
