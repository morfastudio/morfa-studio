# -----------------------------------------------------------
# Creates a Docker image by building and publishing 
# the source within the container
# -----------------------------------------------------------

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

# Copy solution and source
ARG SOLUTION=Smartstore.sln
WORKDIR /app
COPY $SOLUTION ./
COPY src/ ./src
COPY test/ ./test
COPY nuget.config ./

# Create Modules dir if missing
RUN mkdir /app/src/Smartstore.Web/Modules -p -v

# Build
RUN dotnet build $SOLUTION -c Release

# Publish
WORKDIR /app/src/Smartstore.Web
RUN dotnet publish Smartstore.Web.csproj -c Release -o /app/release/publish \
	--no-self-contained \
	--no-restore

# Build Docker image
FROM mcr.microsoft.com/dotnet/aspnet:10.0
EXPOSE 80
EXPOSE 443
ENV ASPNETCORE_URLS="http://+:80;https://+:443"
RUN apt-get update && apt-get install -y --no-install-recommends libgssapi-krb5-2 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/release/publish .
#RUN printf '#!/bin/bash\nset -e\nSETTINGS_FILE="/app/App_Data/Tenants/Default/Settings.txt"\nif [ ! -f "$SETTINGS_FILE" ]; then\n  if [ -z "$CONNECTION_STRING" ]; then\n    echo "ERROR: Settings.txt not found and CONNECTION_STRING is not set."\n    exit 1\n  fi\n  mkdir -p "$(dirname "$SETTINGS_FILE")"\n  printf "AppVersion: ${SMARTSTORE_APP_VERSION:-6.3.0.0}\\nDataProvider: ${SMARTSTORE_DB_PROVIDER:-PostgreSql}\\nDataConnectionString: ${CONNECTION_STRING}\\n" > "$SETTINGS_FILE"\nfi\nexec ./Smartstore.Web --urls http://0.0.0.0:80\n' > entrypoint.sh && chmod +x entrypoint.sh

# Install wkhtmltopdf
# COPY install-wkhtmltopdf.sh /tmp/
# RUN chmod +x /tmp/install-wkhtmltopdf.sh && \
#     /tmp/install-wkhtmltopdf.sh && \
#     rm /tmp/install-wkhtmltopdf.sh

#ENTRYPOINT ["./entrypoint.sh"]
ENTRYPOINT ["./Smartstore.Web", "--urls", "http://0.0.0.0:80"]
