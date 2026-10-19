.PHONY: build release run test decisions
build:
	bash scripts/build.sh
release:
	bash scripts/build.sh release
run: build
	open .build/Bob.app --args --project "$(CURDIR)"
test:
	bash scripts/test.sh
decisions:
	bash scripts/setup-decisions.sh
