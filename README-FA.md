# رهسپار (Rahsepar)

رهسپار یک Deployer سبک و Cross-platform برای استقرار پروژه روی cPanel است. ابزار، مسیر Build تا انتشار نهایی را با FTP، بررسی سلامت و Rollback در یک جریان مشخص نگه می‌دارد.

## اجزای پروژه

- `rahsepar.sh` — کلاینت Linux / macOS
- `rahsepar.ps1` — کلاینت Windows PowerShell
- `rahsepar.cmd` — لانچر Windows
- `extract.php` — endpoint سمت سرور
- `config.example.json` — نمونه پیکربندی
- `docs/` — مستندات استاتیک و کامل
- `Rahsepar-Docs-FA.html` — میانبر ورود به مستندات

## مستندات

برای مشاهده محلی:

```bash
cd docs
python3 -m http.server 8080
```

سپس `http://localhost:8080` را باز کن.

مستندات شامل شروع سریع، راه‌اندازی هاست، پیکربندی، CLI، چرخه Deploy، Watch Mode، Rollback، API، امنیت، Exit Codeها و عیب‌یابی است.
