# pull postgres image
docker pull postgres:14.3
# para criar a imagem
docker build -t custom/postgres:14.3 .  
# para executar
docker run --rm --name="custom_postgres" -e POSTGRES_PASSWORD=dart -v "C:/Program Files/PostgreSQL/docker/volumes/custom_postgres_14.3:/var/lib/postgresql/data:rw" -p 5435:5432 custom/postgres:14.3 &


# para listar containers rodando
docker ps -a 
# para entrar no container
docker exec -it custom_postgres /bin/bash 