NAME="dalibo/temboard"

build:
	docker build --tag $(NAME) .

clean:
	docker images --quiet $(NAME) | xargs --no-run-if-empty --verbose docker rmi -f

dev:
	docker-compose -f ./docker-compose.yml -f ./docker-compose.dev.yml up

push:
	docker push $(NAME)
