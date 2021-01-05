#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <limits.h>
#include <bp_utils.h>

#define N 8

#ifndef NUM_CORES
#define NUM_CORES 2
#endif

int arr[NUM_CORES][N];

void printArray(int arr[], int size)  
{  
    int i;  
    for (i = 0; i < size; i++)  
        bp_printcore("%d ", arr[i]);
    bp_printcore("\n"); 
}

void swap(int *xp, int *yp)  
{  
    int temp = *xp;  
    *xp = *yp;  
    *yp = temp;  
}  
  
// A function to implement bubble sort  
void bubbleSort(int arr[], int n)  
{  
    int i, j;  
    for (i = 0; i < n-1; i++) {      
      printArray(arr, N);
      // Last i elements are already in place  
      for (j = 0; j < n-i-1; j++)  
          if (arr[j] > arr[j+1])  
              swap(&arr[j], &arr[j+1]);  
    }
}

int main(int argc, char** argv) {
  
  uint64_t core_id = bp_get_hart();
  bp_printcore("multicore bubblesort with separate arrays for %d cores, core %d\n", NUM_CORES, core_id);

  int i;
  for(i=0; i<N; i++) {
    arr[core_id][i] = N-i;
  }
  bubbleSort(arr[core_id], N);
  printArray(arr[core_id], N);
  bp_finish(0);
  return 0;
}
