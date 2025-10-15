from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    env: str = "dev"
    database_url: str = "postgresql+psycopg://postgres:postgres@db:5432/cinepulse"
    redis_url: str = "redis://redis:6379/0"
    sentry_dsn_backend: str | None = None

    class Config:
        env_file = ".env"

settings = Settings()
