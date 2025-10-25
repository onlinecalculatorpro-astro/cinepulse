from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # runtime env
    env: str = "dev"

    # backing stores
    database_url: str = "postgresql+psycopg://postgres:postgres@db:5432/cinepulse"
    redis_url: str = "redis://redis:6379/0"

    # feed / cache config (must match sanitizer)
    feed_key: str = "feed:items"
    default_page_size: int = 50  # how many stories /v1/feed returns by default
    max_page_size: int = 100     # hard cap so nobody requests 10k

    # observability
    sentry_dsn_backend: str | None = None

    class Config:
        env_file = ".env"


settings = Settings()
