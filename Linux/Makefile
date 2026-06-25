#
TARGET = PL_PS

#
CROSS_COMPILE = arm-linux-gnueabihf-

CFLAGS = -g -Wall -std=gnu99 -I ${SOCEDS_DEST_ROOT}/ip/altera/hps/altera_hps/hwlib/include

LDFLAGS = -g -Wall
LIBS = -lrt -lpthread

CC = $(CROSS_COMPILE)gcc
ARCH = arm

build: $(TARGET)

$(TARGET): PL_PS.o
	$(CC) $(LDFLAGS) $^ -o $@ $(LIBS)

%.o : %.c
	$(CC) $(CFLAGS) -c $< -o $@

.PHONY: clean
clean:
	rm -f $(TARGET) *.a *.o *~