#!/bin/bash

# Script to automate the setup of GeoNode development environment on Ubuntu-based systems

# Exit immediately if a command exits with a non-zero status
set -e
# Set installation directory
GEONODE_PASSWORD="geonode"
GEONODE_DATA_PASSWORD="geonode_data"
GEOSERVER_ADMIN_PASSWORD="geoserver"
INSTALL_DIR="/home/taufiq/Documents"

mkdir -p "$INSTALL_DIR"
echo "=========================INSTALL_DIR: $INSTALL_DIR ========================= "
cd "$INSTALL_DIR"

# Check if script is run with sudo privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Update package lists
echo "========================= Updating package lists... ========================="
apt-get update

# Install required packages
REQUIRED_PACKAGES=("curl" "git" "python3" "ca-certificates" "gnupg" "lsb-release" "nodejs" "npm")
for PACKAGE in "${REQUIRED_PACKAGES[@]}"; do
    if ! command_exists "$PACKAGE"; then
        echo "========================= Installing $PACKAGE... ========================="
        apt-get install -y "$PACKAGE"
    else
        echo "========================= $PACKAGE is already installed. ========================="
    fi
done

# Install Docker if not installed
if ! command_exists docker; then
    echo "========================= Installing Docker... ========================="
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker "$SUDO_USER"
    echo "Docker installed successfully. Please log out and log back in to apply group changes."
    echo "After logging back in, re-run the script to continue the setup."
    exit 0
else
    echo "========================= Docker is already installed. ========================="
fi

# Install Docker Compose if not installed
if ! command_exists docker-compose; then
    echo "========================= Installing Docker Compose... ========================="
    apt-get install -y docker-compose-plugin
else
    echo "========================= Docker Compose is already installed. ========================="
fi

# Clone the GeoNode repository if not already present
if [ ! -d "$INSTALL_DIR/geonode" ]; then
    echo "========================= Cloning GeoNode repository... ========================="
    git clone https://github.com/GeoNode/geonode.git "$INSTALL_DIR/geonode"
else
    echo "========================= GeoNode repository already exists. ========================="
fi

# Navigate into the cloned repository
cd "$INSTALL_DIR/geonode"

# Create environment file
if [ ! -f ".env" ]; then
    if [ -f "create-envfile.py" ]; then
        echo "========================= Creating environment file... ========================="
        python3 create-envfile.py
    else
        echo "Error: create-envfile.py not found."
        exit 1
    fi
else
    echo "========================= .env file already exists. ========================="
fi



# Update .env file with the database passwords
echo "========================= Updating .env file with database passwords... ========================="
sed -i "s/^GEONODE_DATABASE_PASSWORD=.*/GEONODE_DATABASE_PASSWORD=$GEONODE_PASSWORD/" .env
sed -i "s/^GEONODE_GEODATABASE_PASSWORD=.*/GEONODE_GEODATABASE_PASSWORD=$GEONODE_DATA_PASSWORD/" .env

# Build and bring up the Docker containers
echo "========================= Building and starting Docker containers... ========================="
docker compose --project-name geonode -f docker-compose-dev.yml -f .devcontainer/docker-compose.yml build

# Disable exit on error to prevent script from stopping if django4geonode fails
set +e
docker compose --project-name geonode -f docker-compose-dev.yml -f .devcontainer/docker-compose.yml up -d
DOCKER_UP_EXIT_CODE=$?
set -e

if [ $DOCKER_UP_EXIT_CODE -ne 0 ]; then
    echo "Warning: docker compose up command failed, but continuing script execution."
fi

# Wait for the database container to be ready
echo "========================= Waiting for the database to be ready... ========================="
until docker exec db4geonode pg_isready -U postgres >/dev/null 2>&1; do
    sleep 5
done

# Configure PostgreSQL users
echo "========================= Configuring PostgreSQL users... ========================="
docker exec -i db4geonode psql -U postgres <<EOF
ALTER USER geonode WITH PASSWORD '$GEONODE_PASSWORD';
ALTER USER geonode_data WITH PASSWORD '$GEONODE_DATA_PASSWORD';
EOF


# Wait for GeoServer to be ready
echo "========================= Waiting for GeoServer to be ready... ========================="
until docker exec geoserver4geonode test -f /geoserver_data/data/security/usergroup/default/users.xml; do
    sleep 5
done

# Update GeoServer admin password
echo "========================= Updating GeoServer admin password... ========================="
cat > users.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<userRegistry xmlns="http://www.geoserver.org/security/users" version="1.0">
<users>
<user enabled="true" name="admin" password="plain:$GEOSERVER_ADMIN_PASSWORD"/>
</users>
<groups/>
</userRegistry>
EOF

# Copy users.xml into the container
docker cp users.xml geoserver4geonode:/geoserver_data/data/security/usergroup/default/users.xml

# Remove the local users.xml
rm users.xml

# Restart Docker containers to apply changes
echo "========================= Restarting Docker containers... ========================="
docker compose --project-name geonode -f docker-compose-dev.yml -f .devcontainer/docker-compose.yml restart

cd "$INSTALL_DIR"
# Clone the MapStore2 client repository if not already present
if [ ! -d "$INSTALL_DIR/geonode-mapstore-client" ]; then
    echo "========================= Cloning MapStore2 client repository... ========================="
    git clone --recursive https://github.com/GeoNode/geonode-mapstore-client.git geonode-mapstore-client-dev
else
    echo "========================= MapStore2 client repository already exists. ========================="
fi

# Compile MapStore Client
echo "========================= Compile MapStore2 client... ========================="
cd "$INSTALL_DIR/geonode-mapstore-client-dev/geonode_mapstore_client/client/"
npm update
npm install
npm run compile

cat > env.json <<EOF
{
    "DEV_SERVER_HOST": "localhost:8000",
    "DEV_SERVER_HOST_PROTOCOL": "http"
}
EOF
echo "========================= MapStore2 client Ready... ========================="

# Install Visual Studio Code if not installed
if ! command_exists code; then
    echo "========================= Installing Visual Studio Code... ========================="
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
    install -o root -g root -m 644 packages.microsoft.gpg /usr/share/keyrings/
    sh -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/packages.microsoft.gpg] \
    https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list'
    apt-get update
    apt-get install -y code
    rm -f packages.microsoft.gpg
else
    echo "========================= Visual Studio Code is already installed. ========================="
fi

# Cleanup temporary files
rm -f get-docker.sh

# Completion message
echo "========================= Setup complete. Run ========================="
echo "newgrp docker"
echo "sudo chown -R taufiq:taufiq /home/taufiq/Documents/geonode"
echo "sudo chown -R taufiq:taufiq /home/taufiq/Documents/geonode-mapstore-client-dev"
echo "sudo reboot"
