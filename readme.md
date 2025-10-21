# 🚀 Demo Spring Boot – CI/CD con Azure DevOps, ACR, ACI y Deploy a VM

Este repositorio contiene una app **Spring Boot** y un **pipeline de Azure DevOps** que:
1) compila el `jar`,
2) construye y publica la imagen en **Azure Container Registry (ACR)**,
3) crea/actualiza un contenedor en **Azure Container Instances (ACI)**, y
4) **despliega a una VM** con **backup + restart + health check + rollback automático**.

---

## 🌳 Estructura del proyecto

```
.
├─ .azure/
│  └─ azure-pipelines.yml        # Pipeline principal (YAML)
├─ .mvn/                         # Wrapper Maven
├─ src/
│  ├─ main/java/                 # Código de la app
│  └─ main/resources/
│     ├─ static/                 # Assets estáticos (si aplica)
│     ├─ templates/              # Templates (si aplica)
│     ├─ application.properties
│     └─ application.yml         # Config de Spring (opcional)
├─ target/                       # Salida de build (jar)
├─ .env                          # Variables locales (opcional, no usadas por CI)
├─ .gitattributes
├─ .gitignore
├─ docker-compose.yml            # Opcional para pruebas locales
├─ Dockerfile                    # Build de runtime (si aplica)
├─ mvnw / mvnw.cmd               # Maven wrapper
├─ pom.xml
└─ README.md
```

> **Nota:** el pipeline toma el primer `*.jar` (no `sources`/`javadoc`) de `target/` y lo publica como artefacto `jar/app.jar`.

---

## 🧱 Pipeline Azure DevOps (resumen)

Archivo: **`.azure/azure-pipelines.yml`**  
Trigger: `main` (PR deshabilitado)

### Variables
- **Variable group**: `azure-netby-secrets`
- Derivadas:
    - `IMAGE_NAME = $(AZ_ACR_NAME).azurecr.io/demo-spring`
    - `IMAGE_TAG  = $(Build.BuildId)`

### Stages

#### 1) `deploy` → *Build & Deploy to ACI*
- **Maven Build**: `./mvnw -q -DskipTests clean package` (fallback a `mvn` si no existe wrapper).
- **Publish JAR**: publica artefacto `jar` en la ejecución del pipeline.
- **Login & setup Azure**:
    - `az login` con **Service Principal** (CLIENT_ID/SECRET/TENANT).
    - Selección de **Subscription** y registro de providers `Microsoft.ContainerInstance` y `Microsoft.Network`.
- **ACR**: `az acr login`, build & push de `$(IMAGE_NAME):$(IMAGE_TAG)` y `:latest`.
- **ACI**:
    - Si existe, **borra** el container `$(AZ_ACI_NAME)`.
    - Crea ACI con imagen nueva, **IP pública**, `--dns-name-label $(AZ_ACI_DNS_LABEL)`, puerto `$(APP_PORT)`.
    - Muestra `FQDN` de ACI: `http://<fqdn>:$(APP_PORT)`.

#### 2) `deploy_vm` → *Deploy to VM con rollback*
- **Descarga artefacto** `jar` publicado en el stage anterior.
- **Descarga clave SSH** segura (`DownloadSecureFile@1` → `netby-test_key.pem`).
- **Copia remota**: `scp` a `/tmp/app.jar`.
- **Deploy & backup (SSH)**:
    - Mueve jar a `$(REMOTE_PATH)/app.jar`.
    - Si existe uno previo, lo **respalda** en `$(REMOTE_PATH)/backups/app-<timestamp>.jar`.
    - `systemctl restart $(SERVICE_NAME)`.
- **Health check**:
    - Intenta 30 veces (cada 5s) `curl $(HEALTH_URL)` esperando **HTTP 200**.
    - Si **falla**, ejecuta **rollback** restaurando el último backup y reinicia el servicio.
    - Imprime **logs** del servicio (`journalctl -u $(SERVICE_NAME) -n 200`).
- **Logs (éxito)**: muestra último tail (`-n 60`).

---

## 🔐 Variables requeridas (Library → Variable Group: `azure-netby-secrets`)

> Marca como *secret* cuando corresponda.

| Variable | Descripción |
|---|---|
| `AZURE_CLIENT_ID` | App ID del Service Principal con permisos en la suscripción |
| `AZURE_CLIENT_SECRET` | Secreto del Service Principal |
| `AZURE_TENANT_ID` | Tenant ID (GUID) |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID (GUID) |
| `AZ_ACR_NAME` | Nombre del ACR (sin `.azurecr.io`) |
| `AZ_RESOURCE_GROUP` | Resource Group donde viven ACR/ACI |
| `AZ_ACI_NAME` | Nombre del Container Instance |
| `AZ_ACI_LOCATION` | Región (ej. `eastus`, `westeurope`) |
| `AZ_ACI_DNS_LABEL` | Label DNS público para ACI |
| `APP_PORT` | Puerto que expone la app (ej. `8080`) |
| `ACR_USERNAME` | (Opcional) Usuario ACR si se usa auth básica |
| `ACR_PASSWORD` | (Opcional) Password ACR |
| `REMOTE_HOST` | IP/DNS de la VM destino |
| `REMOTE_USER` | Usuario SSH (ej. `azureuser`) |
| `REMOTE_PATH` | Ruta en VM donde vive la app (ej. `/opt/demo`) |
| `SERVICE_NAME` | Nombre de la unidad `systemd` (ej. `demo.service`) |
| `HEALTH_URL` | URL HTTP para health (ej. `http://ip:8080/actuator/health`) |

**Claves/archivos seguros:**
- `netby-test_key.pem` subido en **Library → Secure files**, referencia directa en el pipeline.
    - El pipeline copia ese archivo a `id_rsa` y ajusta permisos (`chmod 600`).

---

## ⚙️ Requisitos en la VM (systemd + permisos)

1. Crear directorio de la app y backups:
   ```bash
   sudo mkdir -p /opt/demo/backups
   sudo chown azureuser:azureuser /opt/demo
   ```
2. Unidad `systemd` (ej. `/etc/systemd/system/demo.service`):
   ```ini
   [Unit]
   Description=Demo Spring Boot
   After=network.target

   [Service]
   User=azureuser
   WorkingDirectory=/opt/demo
   ExecStart=/usr/bin/java -jar /opt/demo/app.jar
   Restart=always
   RestartSec=5

   [Install]
   WantedBy=multi-user.target
   ```
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable demo
   sudo systemctl start demo
   ```
3. Asegúrate de exponer el puerto (`APP_PORT`) en firewall/NSG.

---

## 🩺 Health check y rollback (detalle)

- Tras reiniciar el servicio, el pipeline intenta `curl $(HEALTH_URL)` hasta **30** veces con una espera de **5s**.
- Si la respuesta != **200**, entonces:
    - Renombra el jar fallido (prefijo `app_failed_` con timestamp).
    - Restaura el **último backup** `backups/app-*.jar`.
    - Reinicia el servicio con la versión estable.
    - Trae **logs** de `journalctl` para diagnóstico y falla el job (salida `exit 1`).

Esto garantiza **despliegues seguros** y reversibles.

---

## 🧪 Logs y troubleshooting

- **ACI**: usa `az container logs -g <rg> -n <aci-name>` para inspeccionar.
- **VM**:
  ```bash
  sudo journalctl -u <SERVICE_NAME> -f
  ```
- Clave SSH debe estar en **formato PEM** y permisos `600`.  
  Si fallas con `OpenSSH` en Windows, convierte si es necesario:
  ```powershell
  ssh-keygen -p -m PEM -f path\to\key
  ```

---

## 🧰 Desarrollo local

- **Con Maven**:
  ```bash
  ./mvnw clean package
  java -jar target/*.jar
  ```
- **Con Docker Compose** (si aplica):
  ```bash
  docker compose up --build
  ```

---

## 🗺️ Endpoints locles (ejemplos)

- App: `http://9.234.136.252:8080/`
- Hello: `http://9.234.136.252:8080/hello`
- Health: `http://9.234.136.252:8080/actuator/health`

- App: `http://localhost:8080/`
- Hello: `http://localhost:8080/hello`
- Health: `http://localhost:8080/actuator/health`

---

## 📌 Notas de seguridad

- **Nunca** expongas secretos en logs/echo.
- Usa **Variable Groups**/Secure Files para credenciales y llaves.
- Limita permisos del Service Principal al **mínimo necesario**.

---

## 📸 Evidencias de ejecución

Todas las evidencias se encuentran en la carpeta `/evidences`.

| Proceso                                | Evidencia                           |
|----------------------------------------|-------------------------------------|
| Build + Push ACR                       | ✅ `/evidences/docker/`              |
| Deploy ACI y VM                        | ✅ `/evidences/pipeline/`            |
| Azure Devops                           | ✅ `/evidences/azure_Devops/`        |
| App (Health, Hello y Pagina principal) | ✅ `/evidences/app/` |

## 👤 Autor

**Daniel Tapia** — DevOps/Cloud  
LinkedIn: https://linkedin.com/in/danieltapia-dev  
GitHub: https://github.com/danieltapia-dev