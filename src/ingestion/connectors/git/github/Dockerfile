FROM airbyte/python-connector-base:2.0.0

COPY . /airbyte/integration_code
RUN pip install /airbyte/integration_code

ENV AIRBYTE_ENTRYPOINT="python /airbyte/integration_code/source_github/source.py"
ENTRYPOINT ["python", "/airbyte/integration_code/source_github/source.py"]
