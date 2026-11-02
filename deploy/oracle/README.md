# Smartstore'u Oracle Cloud (Always Free) VM'de çalıştırma

Bu rehber, projeyi Oracle Cloud'un ücretsiz ARM sanal makinesinde Docker ile çalıştırmayı adım adım anlatır.

**Kurulacak yapı:**

```
İnternet ──443/80──► Caddy (HTTPS, Let's Encrypt) ──► Smartstore (web:80) ──► Neon PostgreSQL
                       │                               │
                       └ caddy-data volume             └ tenants volume (Settings.txt, Media, ...)
```

| Bileşen | Nerede |
|---|---|
| Uygulama | Oracle VM, `web` container (repodaki `Dockerfile` ile build edilir) |
| HTTPS | Oracle VM, `caddy` container, sertifikayı otomatik alır ve yeniler |
| Veritabanı | Neon (harici PostgreSQL) |
| Kalıcı veri | Docker volume `smartstore_tenants` → `/app/App_Data/Tenants` |

Bu klasördeki dosyalar:

| Dosya | Açıklama |
|---|---|
| `docker-compose.yml` | `web` + `caddy` servisleri, volume'lar ve ağ |
| `Caddyfile` | Reverse proxy tanımı |
| `.env.example` | `DOMAIN` değişkeni için şablon. Kopyalanıp `.env` yapılır (`.env` git'e girmez) |

---

## 0. Ön koşullar

- Oracle Cloud hesabı (kayıtta kredi kartı doğrulaması isteniyor, Always Free kaynaklar ücretlendirilmez)
- Neon hesabı (https://neon.tech)
- GitHub'da `morfastudio/morfa-studio` reposuna erişim
- Bilgisayarında bir SSH istemcisi (macOS'ta hazır gelir)

---

## 1. Neon veritabanını oluştur

1. https://console.neon.tech → **New Project**.
2. **Region:** VM ile aynı bölgeyi seç. Oracle'da Frankfurt kullanacaksan Neon'da **AWS Europe Central 1 (Frankfurt)** seç. Smartstore sayfa başına çok sorgu attığı için bölgeler arası gecikme siteyi belirgin şekilde yavaşlatır.
3. **Postgres version:** 17 (ya da sunulan en güncel sürüm).
4. Proje oluşunca **Connect** butonuna bas:
   - **Connection pooling** seçeneğini **kapalı** tut (host adında `-pooler` olmamalı). Kurulum sırasında FluentMigrator migration'ları çalışıyor; PgBouncer'ın transaction modu bunlarla sorun çıkarabilir.
   - Gösterilen URL şuna benzer:
     `postgresql://neondb_owner:ŞİFRE@ep-xxx-123456.eu-central-1.aws.neon.tech/neondb?sslmode=require`
5. Bu URL'yi Smartstore'un (Npgsql) beklediği formata çevir ve bir kenara not et:

   ```
   Host=ep-xxx-123456.eu-central-1.aws.neon.tech;Port=5432;Database=neondb;Username=neondb_owner;Password=ŞİFRE;SSL Mode=Require;Pooling=True;Minimum Pool Size=1;Maximum Pool Size=20
   ```

   `Maximum Pool Size`'ı düşük tut. Neon'un ücretsiz planında bağlantı sayısı sınırlı.

> Neon ücretsiz planında compute bir süre boşta kalınca uyutulur. Uzun aradan sonraki ilk istek birkaç saniye gecikebilir. Bu normaldir.

---

## 2. Oracle Cloud hesabı ve bölge

1. https://cloud.oracle.com → **Sign up**.
2. **Home Region:** Kayıt sırasında seçilir ve **sonradan değiştirilemez**. Always Free ARM makineler yalnızca home region'da açılabilir. Türkiye'den erişim ve Neon'la aynı bölgede olmak için **Germany Central (Frankfurt)** iyi bir seçim.
3. Hesap aktif olunca konsola gir.

> **"Out of capacity" hatası:** Bazı bölgelerde ARM kapasitesi dolu olabiliyor. Bu durumda birkaç saat sonra tekrar dene ya da farklı bir Availability Domain seç (AD-1/2/3). Hesabı "Pay As You Go"ya yükseltmek kapasite bulmayı kolaylaştırıyor ve Always Free limitleri içinde kaldıkça ücret çıkmıyor, ama limiti aşarsan ücretlendirilirsin. Bunu bilerek karar ver.

---

## 3. VM'i oluştur

Konsolda: **☰ Menü → Compute → Instances → Create instance**

| Alan | Değer |
|---|---|
| **Name** | `smartstore` |
| **Compartment** | root (varsayılan) |
| **Placement** | Varsayılan AD. Kapasite hatası alırsan diğerini dene |
| **Image** | **Change image** → **Canonical Ubuntu** → **24.04** (Minimal *olmayan*). Docker imajı da Ubuntu 24.04 (noble) tabanlı |
| **Shape** | **Change shape** → **Virtual machine** → **Ampere** → **VM.Standard.A1.Flex** |
| **OCPU / Memory** | **2 OCPU, 12 GB**. Always Free ARM kotasının tamamı bu kadar |
| **Networking** | **Create new virtual cloud network** ve **Create new public subnet** (varsayılanlar) |
| **Public IPv4** | **Automatically assign public IPv4 address** → açık |
| **SSH keys** | **Generate a key pair for me** → **Save private key** (`.key` dosyasını indir). Ya da kendi public key'ini yapıştır |
| **Boot volume** | Varsayılan (~47 GB) yeterli. Always Free toplam 200 GB block storage içeriyor |

**Create** butonuna bas. Birkaç dakika içinde durum **Running** olur. Instance sayfasındaki **Public IP address** değerini not et (örneklerde `141.147.12.34`).

> **Sabit IP:** Varsayılan IP "ephemeral"dir: makine durup başlasa da aynı kalır, ama makineyi silip yeniden oluşturursan değişir. Sabit IP için: Instance → **Attached VNICs** → VNIC → **IPv4 Addresses** → **Edit** → **Reserved public IP**. Bunun Always Free kapsamında olup olmadığını konsoldaki uyarıdan kontrol et.

---

## 4. Oracle güvenlik duvarında 80 ve 443'ü aç (Security List)

Yeni VCN'de varsayılan olarak sadece 22 (SSH) açıktır.

1. Instance sayfası → **Primary VNIC** bölümünde **Subnet** linkine tıkla.
2. **Security** (ya da **Security Lists**) → **Default Security List for vcn-...** → **Security rules** → **Add Ingress Rules**.
3. İki kural ekle:

| Source CIDR | IP Protocol | Destination Port Range | Açıklama |
|---|---|---|---|
| `0.0.0.0/0` | TCP | `80` | HTTP (Let's Encrypt doğrulaması için de gerekli) |
| `0.0.0.0/0` | TCP | `443` | HTTPS |

İstersen HTTP/3 için `0.0.0.0/0`, **UDP**, `443` kuralını da ekleyebilirsin (opsiyonel).

---

## 5. VM'e SSH ile bağlan

Bilgisayarında:

```bash
chmod 600 ~/Downloads/ssh-key-*.key
ssh -i ~/Downloads/ssh-key-*.key ubuntu@141.147.12.34
```

Ubuntu imajında kullanıcı adı `ubuntu`.

İstersen `~/.ssh/config` dosyasına bir kısayol ekle:

```
Host smartstore-oci
    HostName 141.147.12.34
    User ubuntu
    IdentityFile ~/.ssh/oci-smartstore.key
```

Sonra sadece `ssh smartstore-oci` yazman yeterli.

---

## 6. VM hazırlığı

Aşağıdaki komutlar **VM üzerinde** çalıştırılır.

### 6.1 Sistem güncellemesi

```bash
sudo apt update && sudo apt -y upgrade
sudo timedatectl set-timezone Europe/Istanbul
```

Kernel güncellendiyse `sudo reboot` ile yeniden başlat ve tekrar bağlan.

### 6.2 İşletim sistemi güvenlik duvarı (iptables)

Oracle'ın Ubuntu imajında, Security List'ten bağımsız olarak **ikinci bir güvenlik duvarı** (`iptables`) gelir ve 22 dışındaki portları reddeder. 80 ve 443'ü aç ve kalıcı kaydet:

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT 6 -p udp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

Kontrol:

```bash
sudo iptables -L INPUT -n --line-numbers
```

`ACCEPT` kuralları, en alttaki `REJECT ... icmp-host-prohibited` satırından **önce** görünmeli.

> `ufw` kullanma. Oracle'ın iptables kurallarıyla ve Docker'la çakışıyor.

### 6.3 Docker kurulumu

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu
```

Grup değişikliğinin etkin olması için **çıkış yapıp tekrar bağlan** (`exit`, sonra `ssh ...`). Kontrol:

```bash
docker version
docker compose version
```

Docker servisi açılışta otomatik başlar. Container'lar `restart: unless-stopped` olduğu için VM yeniden başladığında kendiliğinden ayağa kalkar.

---

## 7. Kodu VM'e al

Repo private olduğu için VM'e salt okunur bir **deploy key** tanımla.

### 7.1 VM'de anahtar oluştur

```bash
ssh-keygen -t ed25519 -C "oci-smartstore" -f ~/.ssh/github_deploy -N ""
cat ~/.ssh/github_deploy.pub
```

### 7.2 GitHub'a ekle

GitHub → `morfastudio/morfa-studio` → **Settings → Deploy keys → Add deploy key**
- Title: `oci-smartstore`
- Key: yukarıdaki `.pub` çıktısı
- **Allow write access:** kapalı

### 7.3 SSH ayarı ve clone

```bash
cat >> ~/.ssh/config <<'EOF'
Host github.com
    IdentityFile ~/.ssh/github_deploy
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

git clone git@github.com:morfastudio/morfa-studio.git ~/morfa-studio
cd ~/morfa-studio
git checkout master
```

---

## 8. Alan adını belirle ve `.env` dosyasını oluştur

Kendi alan adın yoksa **sslip.io** kullan: IP'deki noktaları tireye çevir. Herhangi bir kayıt gerekmez.

| Public IP | DOMAIN |
|---|---|
| `141.147.12.34` | `141-147-12-34.sslip.io` |

Kendi alan adın varsa (ör. `test.morfa.studio`), DNS'te bu ada VM IP'sini gösteren bir **A kaydı** ekle ve DNS yayılana kadar bekle (`dig +short test.morfa.studio` IP'yi döndürmeli).

```bash
cd ~/morfa-studio/deploy/oracle
cp .env.example .env
nano .env        # DOMAIN=141-147-12-34.sslip.io
```

---

## 9. Build et ve başlat

```bash
cd ~/morfa-studio/deploy/oracle
docker compose up -d --build
```

- İlk build **uzun sürer**: tüm solution ve modüller container içinde derlenir. 2 OCPU'da 15-30 dakika sürebilir.
- `Dockerfile` hedef mimariyi kendisi algılar (ARM VM'de `linux-arm64`).

İlerlemeyi ve logları izle:

```bash
docker compose ps
docker compose logs -f web      # Smartstore
docker compose logs -f caddy    # sertifika alımı
```

Caddy loglarında `certificate obtained successfully` görmelisin. Görmüyorsan [Sorun giderme](#13-sorun-giderme) bölümüne bak.

---

## 10. Smartstore kurulum sihirbazı

Tarayıcıda `https://141-147-12-34.sslip.io` adresini aç. Kurulum ekranı gelir.

| Alan | Değer |
|---|---|
| **Admin e-posta / şifre** | Güçlü bir şifre seç. Site internete açık |
| **Primary language** | İstediğin dil |
| **Install sample data** | Test için açabilirsin. Neon ücretsiz depolama kotasını doldurabilir; emin değilsen kapalı bırak |
| **Media storage** | **File system** seç. Medya `tenants` volume'unda tutulur, Neon kotasını harcamaz |
| **DB system** | **PostgreSQL** |
| **Connection** | **Raw connection string** |
| **Connection string** | 1. adımda hazırladığın Npgsql connection string |
| **Custom collation** | Kapalı |

**Install** butonuna bas. Kurulum birkaç dakika sürer (migration + seed). Bittiğinde uygulama yeniden başlar.

Bu noktada `Settings.txt` ve `InstalledModules.txt` `tenants` volume'una yazılmıştır. Sonraki deploy'larda kurulum ekranı **tekrar gelmez**.

---

## 11. Kurulum sonrası ayarlar

1. **Mağaza URL'si:** Admin → **Configuration → Stores** → mağazayı düzenle:
   - **Store URL:** `https://141-147-12-34.sslip.io/`
   - **SSL enabled:** açık

   Bunu yapmazsan e-postalardaki linkler, yönlendirmeler ve bazı asset URL'leri yanlış adrese gider.
2. **E-posta hesabı:** Admin → Configuration → Email accounts. Sipariş ve şifre sıfırlama e-postaları için bir SMTP hesabı tanımla.
3. **PDF (opsiyonel):** Fatura/PDF çıktısı gerekiyorsa repodaki `Dockerfile`'da `# Install wkhtmltopdf` altındaki üç satırın yorumunu kaldır ve yeniden deploy et (bkz. 12. adım).

---

## 12. Güncelleme (yeniden deploy)

Kodda değişiklik yaptığında, VM'de:

```bash
cd ~/morfa-studio
git pull
cd deploy/oracle
docker compose up -d --build
docker image prune -f      # eski imaj katmanlarını temizle
```

- `tenants` volume'u korunduğu için DB bağlantısı, kurulu modüller, medya ve DataProtection anahtarları kaybolmaz. Kullanıcıların oturumu da düşmez.
- Build sürerken eski container çalışmaya devam eder. Kesinti sadece container değişimi ve uygulamanın açılışı sırasında yaşanır (yaklaşık 30-60 saniye).
- Yeni sürümde DB migration varsa uygulama açılışta otomatik çalıştırır.

**Asla** `docker compose down -v` çalıştırma: `-v` volume'ları siler, kurulum ve medya kaybolur.

---

## 13. Sorun giderme

| Belirti | Olası neden / çözüm |
|---|---|
| Site hiç açılmıyor, zaman aşımı | 4. adım (Security List) veya 6.2 (iptables) eksik. VM'de `curl -I http://localhost` çalışıyorsa sorun güvenlik duvarındadır |
| Caddy: `challenge failed` / sertifika alınamıyor | 80 portu dışarıdan erişilemiyor ya da `DOMAIN` VM'in IP'sini göstermiyor. `dig +short $DOMAIN` ile kontrol et. Çok sayıda başarısız denemeden sonra Let's Encrypt bir süre bekletir |
| `ERR_TOO_MANY_REDIRECTS` (SSL açıldıktan sonra) | Smartstore Caddy'nin `X-Forwarded-Proto` header'ına güvenmiyor. `docker-compose.yml`'daki `KnownNetworks` değerinin ağın subnet'iyle (`172.30.0.0/24`) aynı olduğundan emin ol |
| Kurulumda DB bağlantı hatası | Connection string'de `SSL Mode=Require` var mı? Host'ta `-pooler` olmamalı. Neon şifresinde `;` varsa şifreyi tırnak içine al (`Password='...'`) |
| Build sırasında `You must install or update .NET` | `Dockerfile`'da `ENV DOTNET_ROLL_FORWARD=Major` satırı olmalı |
| Kurulum ekranı her deploy'da tekrar geliyor | `tenants` volume'u bağlı değil ya da silinmiş. `docker volume ls` ile `smartstore_tenants` volume'unu kontrol et |
| Uygulama hatası | `docker compose logs --tail 200 web` ve container içindeki log dosyaları: `docker compose exec web ls /app/App_Data/Logs` |

Faydalı komutlar:

```bash
docker compose ps                         # durum
docker compose restart web                # uygulamayı yeniden başlat
docker stats                              # CPU/RAM kullanımı
docker compose exec web cat /app/App_Data/Tenants/Default/Settings.txt
```

---

## 14. Yedekleme

**Veritabanı:** Neon'un kendi geçmiş/restore özelliği var. Ücretsiz plandaki saklama süresi kısa olduğu için önemli verilerde ayrıca `pg_dump` al.

**Tenants volume'u** (medya, ayarlar, anahtarlar):

```bash
mkdir -p ~/backups
docker run --rm -v smartstore_tenants:/data -v ~/backups:/backup alpine \
  tar czf /backup/tenants-$(date +%F).tar.gz -C /data .
```

Geri yükleme (uygulama durdurulmuşken):

```bash
docker compose stop web
docker run --rm -v smartstore_tenants:/data -v ~/backups:/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/tenants-2026-11-02.tar.gz -C /data"
docker compose start web
```

Yedekleri VM dışına da kopyala (ör. `scp smartstore-oci:~/backups/*.tar.gz .`). VM silinirse VM'deki yedekler de gider.

---

## 15. Güvenlik notları

- SSH yalnızca anahtarla çalışır (Oracle varsayılanı). Private key'i paylaşma.
- Uygulama portu (80) dışarıya açılmaz. Dışarıdan sadece Caddy'ye (80/443) erişilir.
- Admin şifresini güçlü tut. Site test amaçlı olsa da internete açık.
- `.env` ve Neon şifresi git'e girmez (`deploy/oracle/.gitignore`). Connection string sadece `tenants` volume'undaki `Settings.txt` dosyasında durur.
- Always Free hesaplarda uzun süre kullanılmayan kaynaklar geri alınabiliyor. Ara sıra kullanım/erişim olmasında fayda var.
