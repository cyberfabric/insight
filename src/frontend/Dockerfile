# Multi-stage build for Insight Frontend
#
# Build context: the insight-front directory (via symlink or direct path)
# Usage: docker build -t insight-frontend:local -f src/frontend/Dockerfile ../insight-front_symlink
#
# Runtime OIDC config: pass OIDC_ISSUER and OIDC_CLIENT_ID env vars
# to inject window.__OIDC_CONFIG__ into index.html at container start.

# Stage 1: Build
FROM node:25-bookworm-slim AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

COPY . .
RUN npm run build

# Stage 2: Serve with nginx
FROM nginx:1.27-alpine

COPY --from=builder /app/dist /usr/share/nginx/html
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
COPY <<'NGINX' /etc/nginx/conf.d/default.conf
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    # SPA: serve index.html for all routes
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Health check
    location /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok";
    }
}
NGINX

EXPOSE 80
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
