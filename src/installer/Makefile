CC ?= cc
CFLAGS ?= -O2 -std=c99 -Wall -Wextra -Werror
CPPFLAGS ?=
LDFLAGS ?=

SOURCES = main.c run.c
HEADERS = installer.h

all: keel-install

keel-install: $(SOURCES) $(HEADERS)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS)

clean:
	rm -f keel-install

.PHONY: all clean
