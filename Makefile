PRIV_DIR := $(MIX_APP_PATH)/priv
NIF := $(PRIV_DIR)/handbeam_storage.so
ERTS_INCLUDE_DIR := $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
CFLAGS ?= -O2 -fPIC -Wall -Wextra -Werror
ifeq ($(shell uname -s),Darwin)
LDFLAGS += -undefined dynamic_lookup
endif

.PHONY: all clean
all: $(NIF)

$(NIF): c_src/handbeam_storage.c
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -shared $(LDFLAGS) -o $@ $<

clean:
	rm -f $(NIF)
