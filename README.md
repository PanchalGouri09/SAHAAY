# SAHAAY

## Live demo and release checklist

- Deploy `sahaay_backend` and `sahaay-ai-service` from their directories using
  the provided Dockerfiles. Configure Supabase and Firebase credentials only
  in the backend host's secret store; keep the AI service private because it
  does not authenticate callers.
- Set the backend's `AI_SERVICE_URL` to the deployed AI service's private
  address. Keep one backend replica while the in-process offer/escalation
  schedulers are enabled, and confirm both `/health` endpoints.
- Review the actual Supabase migration history and schema before deployment.
  The canonical local migration sequence is `sahaay_backend/supabase/migrations`;
  migrations are not applied by startup or by this checklist.
- Before the final APK build, set the one deployment-specific Flutter value,
  `API_BASE_URL`, in ignored `sahaay/env.json` to the verified HTTPS backend
  origin. Ensure the ignored Firebase and Maps configuration files are present
  locally and their Android package, signing fingerprint, API enablement, and
  billing restrictions are correct.
- From `sahaay`, build with:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1 `
    -ConfigFile env.json `
    -FlutterExecutable 'C:\Users\admin\Downloads\Flutter\flutter\bin\flutter.bat'
  ```

  The current release variant is debug-signed for demo/testing and is not
  production-distribution signed. Do not put Supabase service-role or Firebase
  Admin credentials in Flutter configuration.