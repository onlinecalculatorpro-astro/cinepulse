import os
from rq import Worker, Queue
from redis import Redis

def main():
    conn = Redis.from_url(os.getenv("REDIS_URL", "redis://redis:6379/0"))
    q_default = Queue("default", connection=conn)
    q_events  = Queue("events",  connection=conn)
    worker = Worker([q_default, q_events], connection=conn)
    worker.work(with_scheduler=True)

if __name__ == "__main__":
    main()
