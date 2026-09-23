from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    supabase_url: str = Field(default="", validation_alias="SUPABASE_URL")
    supabase_service_role_key: str = Field(default="", validation_alias="SUPABASE_SERVICE_ROLE_KEY")
    firebase_project_id: str = Field(default="", validation_alias="FIREBASE_PROJECT_ID")
    firebase_client_email: str = Field(default="", validation_alias="FIREBASE_CLIENT_EMAIL")
    firebase_private_key: str = Field(default="", validation_alias="FIREBASE_PRIVATE_KEY")
    cors_origins: str = Field(default="http://localhost:3000,http://localhost:5000", validation_alias="CORS_ORIGINS")
    ai_service_url: str = Field(default="http://127.0.0.1:8001", validation_alias="AI_SERVICE_URL")
    ai_request_timeout_seconds: float = Field(default=15.0, validation_alias="AI_REQUEST_TIMEOUT_SECONDS")
    supabase_storage_bucket: str = Field(default="donations", validation_alias="SUPABASE_STORAGE_BUCKET")
    max_food_photo_size_mb: int = Field(default=5, validation_alias="MAX_FOOD_PHOTO_SIZE_MB")
    escalation_scheduler_enabled: bool = Field(default=True, validation_alias="ESCALATION_SCHEDULER_ENABLED")
    escalation_scheduler_interval_seconds: int = Field(default=60, validation_alias="ESCALATION_SCHEDULER_INTERVAL_SECONDS")

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def firebase_configured(self) -> bool:
        return all((self.firebase_project_id, self.firebase_client_email, self.firebase_private_key))

    @property
    def supabase_configured(self) -> bool:
        return bool(self.supabase_url and self.supabase_service_role_key)


@lru_cache
def get_settings() -> Settings:
    return Settings()
