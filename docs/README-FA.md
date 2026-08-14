# مستندات وب رهسپار

یک سایت استاتیک، بدون Build Tool و بدون Dependency خارجی برای مستندات رهسپار.

## اجرای محلی

```bash
cd docs
python3 -m http.server 8080
```

یا:

```bash
cd docs
php -S localhost:8080
```

سپس `http://localhost:8080` را باز کن.

## ساختار

- `index.html` — صفحه اصلی مستندات
- `assets/styles.css` — طراحی Responsive، Light/Dark و کامپوننت‌های Docs
- `assets/app.js` — جست‌وجو، Theme، Copy، ناوبری و Demo ترمینال
- `downloads/` — فایل‌های قابل دانلود رهسپار

## انتشار

تمام محتویات پوشه `docs/` را روی هر Static Host یا وب‌سرور دلخواه قرار بده. فایل ورودی `index.html` است.
