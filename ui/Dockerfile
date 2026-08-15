FROM python:3.12-slim
# psycopg's binary wheel keeps the image free of a build toolchain and libpq.
RUN pip install --no-cache-dir "psycopg[binary]==3.2.3"
WORKDIR /app
COPY app.py index.html ./
EXPOSE 8080
CMD ["python", "-u", "app.py"]
