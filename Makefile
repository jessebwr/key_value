all: compile

compile:
	erlc -o ebin/ src/*.erl

clean:
	rm *.beam
