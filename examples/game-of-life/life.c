/*
 * Conway's Game of Life — deterministic reference.
 *
 * Based on RuiBorgesDev/CGameOfLife (GameOfLife.c), trimmed for a reproducible
 * stdout-diff test: removed the Windows/Unix animation shell (getopt, rand/srand,
 * sleep, system("clear"), cursor escapes, RANDOM pattern). The core algorithm
 * (grid evolve, named patterns, ring-buffer loop detection) is kept verbatim.
 *
 * Runs a fixed PULSAR pattern (period-3 oscillator) on a 17x17 bounded grid until
 * the loop detector fires, printing each generation as an ASCII frame.
 *
 * This is the ESPECTED-output oracle: the SexC port in main.sexc must reproduce
 * its stdout byte-for-byte.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEAD '.'
#define ALIVE 'o'
#define BLINKER 0
#define TOAD 1
#define BEACON 2
#define PULSAR 3
#define PENTADECATHLON 4
#define GLIDER 5
#define GOSPER_GLIDER_GUN 6
#define LWSS 7

#define MAX_ITER 100
#define LOOPWINDOW 5

unsigned int GLOBAL_nlines = 0;
unsigned int GLOBAL_ncolumns = 0;
unsigned int GLOBAL_loopwindow = LOOPWINDOW;

char **history = NULL;

void gridInit(char **history, int pattern){
    for (int g = 0; g < GLOBAL_loopwindow; g++){
        for (int i = 0; i < GLOBAL_ncolumns * GLOBAL_nlines; i++){
            history[g][i] = DEAD;
        }
    }
    switch (pattern){
    case BLINKER:
        history[1][11] = history[1][12] = history[1][13] = ALIVE;
        break;
    case TOAD:
        history[1][14] = history[1][15] = history[1][16] = history[1][19] = history[1][20] = history[1][21] = ALIVE;
        break;
    case BEACON:
        history[1][7] = history[1][8] = history[1][13] = history[1][22] = history[1][27] = history[1][28] = ALIVE;
        break;
    case PULSAR:
        history[1][22] = history[1][28] = history[1][39] = history[1][45] = history[1][56] = history[1][57] = history[1][61] = history[1][62] = history[1][86] = history[1][87] = history[1][88] = history[1][91] = history[1][92] = history[1][94] = history[1][95] = history[1][98] = history[1][99] = history[1][100] = history[1][105] = history[1][107] = history[1][109] = history[1][111] = history[1][113] = history[1][115] = history[1][124] = history[1][125] = history[1][129] = history[1][130] = history[1][158] = history[1][159] = history[1][163] = history[1][164] = history[1][173] = history[1][175] = history[1][177] = history[1][179] = history[1][181] = history[1][183] = history[1][188] = history[1][189] = history[1][190] = history[1][193] = history[1][194] = history[1][196] = history[1][197] = history[1][200] = history[1][201] = history[1][202] = history[1][226] = history[1][227] = history[1][231] = history[1][232] = history[1][243] = history[1][249] = history[1][260] = history[1][266] = ALIVE;
        break;
    case PENTADECATHLON:
        history[1][37] = history[1][38] = history[1][39] = history[1][49] = history[1][60] = history[1][70] = history[1][71] = history[1][72] = history[1][92] = history[1][93] = history[1][94] = history[1][103] = history[1][104] = history[1][105] = history[1][125] = history[1][126] = history[1][127] = history[1][137] = history[1][148] = history[1][158] = history[1][159] = history[1][160] = ALIVE;
        break;
    case GLIDER:
        history[1][1] = history[1][17] = history[1][30] = history[1][31] = history[1][32] = ALIVE;
        break;
    case LWSS:
        history[1][31] = history[1][34] = history[1][65] = history[1][91] = history[1][95] = history[1][122] = history[1][123] = history[1][124] = history[1][125] = ALIVE;
        break;
    }
}

int gridCompare(char **history){
    size_t gridSize = GLOBAL_ncolumns * GLOBAL_nlines * sizeof(char);
    if (gridSize == 0){
        return 0;
    }
    for (int i = 1; i < GLOBAL_loopwindow; i++){
        if (memcmp(history[0], history[i], gridSize) == 0){
            return i;
        }
    }
    return 0;
}

void gridEvolve(char *current, char *next){
    int row, col;
    for(int i = 0; i < GLOBAL_ncolumns * GLOBAL_nlines; i++){
        row = i / GLOBAL_ncolumns, col = i % GLOBAL_ncolumns;
        int count = 0;
        for(int j = col - 1; j <= col + 1 && count <= 4; j++){
            for(int k = row - 1; k <= row + 1; k++){
                if((j == col && k == row) || (j < 0 || j >= GLOBAL_ncolumns) || (k < 0 || k >= GLOBAL_nlines)){
                    continue;
                }
                if(current[k * GLOBAL_ncolumns + j] == ALIVE) {
                    count++;
                }
            }
        }
        next[i] = count == 3 || (count == 2 && current[i] == ALIVE) ? ALIVE : DEAD;
    }
}

void defineDimensions(int pattern){
    switch (pattern){
    case BLINKER:
        GLOBAL_nlines = GLOBAL_ncolumns = 5;
        break;
    case TOAD:
    case BEACON:
        GLOBAL_nlines = GLOBAL_ncolumns = 6;
        break;
    case PULSAR:
        GLOBAL_nlines = GLOBAL_ncolumns = 17;
        break;
    case PENTADECATHLON:
        GLOBAL_nlines = 18;
        GLOBAL_ncolumns = 11;
        break;
    case GLIDER:
        GLOBAL_nlines = GLOBAL_ncolumns = 15;
        break;
    case LWSS:
        GLOBAL_nlines = 7;
        GLOBAL_ncolumns = 30;
        break;
    }
}

void gridShow(char *grid){
    if (!grid || GLOBAL_nlines == 0 || GLOBAL_ncolumns == 0){
        return;
    }
    for (int i = 0; i < GLOBAL_nlines; i++){
        fwrite(grid + i * GLOBAL_ncolumns, sizeof(char), GLOBAL_ncolumns, stdout);
        putchar('\n');
    }
}

void slideHistory(char **history){
    if (!history || GLOBAL_loopwindow < 2){
        return;
    }
    char *temp_oldest_buffer = history[GLOBAL_loopwindow - 1];
    for (int g = GLOBAL_loopwindow - 1; g > 0; g--){
        history[g] = history[g - 1];
    }
    history[0] = temp_oldest_buffer;
}

int main(void){
    unsigned int pattern = PULSAR;
    unsigned int maxNumIters = MAX_ITER;
    GLOBAL_loopwindow = LOOPWINDOW;

    defineDimensions(pattern);

    history = malloc(GLOBAL_loopwindow * sizeof(char *));
    if (!history){
        fprintf(stderr, "Error: Memory allocation failed.\n");
        exit(EXIT_FAILURE);
    }
    for (int i = 0; i < GLOBAL_loopwindow; i++){
        history[i] = malloc(GLOBAL_ncolumns * GLOBAL_nlines * sizeof(char));
        if (!history[i]){
            fprintf(stderr, "Error: Memory allocation failed for history[%d].\n", i);
            exit(EXIT_FAILURE);
        }
    }
    gridInit(history, pattern);

    unsigned int niter = 0;
    int loop_found = 0;
    while (niter < maxNumIters){
        gridShow(history[1]);
        printf("Iteration: %u / %u\n", niter + 1, maxNumIters);
        gridEvolve(history[1], history[0]);
        int loop_period = gridCompare(history);
        if (loop_period > 0){
            printf("\nLoop detected after %u iterations!\n", niter + 1);
            printf("Loop Period: %d\n", loop_period);
            loop_found = 1;
            break;
        }
        slideHistory(history);
        niter++;
    }
    if (!loop_found && niter == maxNumIters){
        printf("\nMaximum iterations (%u) reached without detecting a loop (within history window %u).\n", maxNumIters, GLOBAL_loopwindow);
    }
    if (history){
        for (int i = 0; i < GLOBAL_loopwindow; i++){
            if (history[i]){
                free(history[i]);
            }
        }
        free(history);
    }
    return 0;
}
