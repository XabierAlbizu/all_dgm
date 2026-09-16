#!/bin/bash
set -e

echo "Preparando entorno para code-server (VSCode)..."

# Hostname corto del nodo de ejecución (para el proxy OOD)
host="$(hostname -s)"
export host
export HOST="$host"

# Puerto libre vía helper OOD
# Rango acotado a 30000-30999: el proxy de OOD conecta desde la cabecera al
# nodo, y ese tramo necesita una regla de red explicita. Un rango contiguo y
# estrecho es lo que hace la peticion aceptable. NO ampliar sin pedirlo a Redes.
port="$(find_port localhost 30000 30999)"
export port
export PORT="$port"

# Password aleatorio (lo usará code-server con --auth password,
# y view.html.erb lo envía por POST al proxy OOD).
password="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-24)"
export password

# Base URL útil para diagnóstico
external_host="$(hostname -I | awk '{print $1}')"
export base_url="http://${external_host}:${port}"
