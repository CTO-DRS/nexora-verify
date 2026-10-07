# DRS NEXORA — Verification Site

صفحات التحقق الرسمية لتطبيق **DRS NEXORA** (تأكيد التسجيل / تعيين كلمة المرور).
مستضافة عبر GitHub Pages على هذا المستودع.

**الرابط المباشر:** `https://cto-drs.github.io/nexora-verify/`

| الصفحة | الوظيفة |
|---|---|
| `index.html` | صفحة الهبوط + توجيه تلقائي حسب نوع عملية التحقق |
| `confirm.html` | تأكيد التسجيل (type=signup) وتأكيد تغيير البريد (type=email_change) |
| `reset.html` | تعيين/إعادة تعيين كلمة المرور (type=recovery) وأول كلمة مرور للدعوات (type=invite) |

- **المصدر الحقيقي للملفات** داخل مستودع التطبيق: `drs-nexora/verification-site/` — أي تعديل يتم هناك ثم يُنشر بالسكربت `scripts/deploy-verify-site.sh` من مستودع التطبيق.
- الصفحات تستخدم مفتاح Supabase **publishable** فقط (عام بطبيعته، مثل مفاتيح Firebase العامة).
- لا تُخزَّن أي جلسات على هذا النطاق (`persistSession: false`).
- تُضاف هذه الروابط إلى قائمة **Redirect URLs** في لوحة Supabase — التفاصيل الكاملة في مستودع التطبيق: `docs/EMAIL_SETUP.md`.
