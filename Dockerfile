FROM python:3.12-slim

WORKDIR /app
ENV PYTHONUNBUFFERED=1
COPY services /app/services

EXPOSE 8000

