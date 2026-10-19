# ack-api: Python 3.12 + PyMySQL（基础镜像来自 ACR；pip 走阿里云镜像源）
FROM crpi-xxxxxxxxxxxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com/yunshiyan/ack-api:python-3.12-alpine
WORKDIR /app
RUN pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ pymysql==1.2.3
COPY app.py /app/app.py
EXPOSE 8080
CMD ["python", "/app/app.py"]