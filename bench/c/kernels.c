/* The kernels of bench/c/kernels.tcl in C, as a C programmer would write them (gcc -O2). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static long k_arith(long n) { long s = 0; for (long i = 0; i < n; i++) s = (s + i * 3) % 1000003; return s; }
static long k_collatz(long n) { long best = 0; for (long i = 1; i < n; i++) { long x = i, c = 0; while (x != 1) { if (x % 2) x = 3 * x + 1; else x = x / 2; c++; } if (c > best) best = c; } return best; }
static long k_fib(long n) { return n < 2 ? n : k_fib(n - 1) + k_fib(n - 2); }
static long k_sieve(long n) { char *p = malloc(n + 1); for (long i = 0; i <= n; i++) p[i] = 1; for (long i = 2; i * i <= n; i++) if (p[i]) for (long j = i * i; j <= n; j += i) p[j] = 0; long c = 0; for (long i = 2; i <= n; i++) if (p[i]) c++; free(p); return c; }
static long k_mat(long n) { long *a = malloc(n*n*8), *b = malloc(n*n*8); for (long i = 0; i < n; i++) for (long j = 0; j < n; j++) { a[i*n+j] = i + j; b[i*n+j] = i - j; } long t = 0; for (long i = 0; i < n; i++) for (long j = 0; j < n; j++) { long s = 0; for (long k = 0; k < n; k++) s += a[i*n+k] * b[k*n+j]; t += s; } free(a); free(b); return t; }
static long k_hist(long n) { long h[1000]; memset(h, 0, sizeof h); for (long i = 0; i < n; i++) h[(i * 7) % 1000]++; long s = 0; for (long k = 0; k < 1000; k++) s += h[k] * k; return s; }
static long k_dotd(long n) { double *x = malloc(n * 8), *y = malloc(n * 8); for (long i = 0; i < n; i++) { x[i] = i * 0.5; y[i] = i / 4.0; } double s = 0.0; for (long i = 0; i < n; i++) s += x[i] * y[i]; free(x); free(y); return (long) s; }
static long k_lcs(long n) { char *x = malloc(n + 1), *y = malloc(n + 1); for (long i = 0; i < n; i++) { x[i] = "abcd"[(i * 7) % 4]; y[i] = "abcd"[(i * 5 + 1) % 4]; } long w = n + 1; long *d = calloc(w * w, 8); for (long i = 1; i <= n; i++) for (long j = 1; j <= n; j++) { if (x[i-1] == y[j-1]) d[i*w+j] = d[(i-1)*w+j-1] + 1; else { long u = d[(i-1)*w+j], l = d[i*w+j-1]; d[i*w+j] = u > l ? u : l; } } long r = d[n*w+n]; free(x); free(y); free(d); return r; }
static long k_lsum(long n) { long *l = malloc(n * 8); for (long i = 0; i < n; i++) l[i] = i * 3 % 1001; long s = 0; for (long i = 0; i < n; i++) s += l[i]; free(l); return s; }
static long k_lfor(long n) { long *l = malloc(n * 8); for (long i = 0; i < n; i++) l[i] = i * 7 % 1009; long s = 0; for (long i = 0; i < n; i++) if (l[i] > 500) s += l[i]; free(l); return s; }
static long k_lset(long n) { long *l = calloc(n, 8); for (long i = 0; i < n; i++) l[i] = i * i % 997; long s = 0; for (long i = 1; i < n; i++) s += l[i] - l[i - 1]; free(l); return s; }
static long k_dict(long n) { long d[5000]; memset(d, 0, sizeof d); for (long i = 0; i < n; i++) d[i * 13 % 5000]++; long s = 0; for (long k = 0; k < 5000; k++) s += k * d[k]; return s; }
static long k_str(long n) { char *s = malloc(n + 1); for (long i = 0; i < n; i++) s[i] = "abcdefghij"[i % 10]; long c = 0; for (long i = 0; i < n; i++) if (s[i] == 'e') c++; free(s); return c * 1000000000L + n; }
int main(void) {
    struct { const char *nm; long (*f)(long); long arg; } c[] = {
        {"k_arith", k_arith, 20000000}, {"k_collatz", k_collatz, 100000}, {"k_fib", k_fib, 30}, {"k_sieve", k_sieve, 3000000}, {"k_mat", k_mat, 120},
        {"k_hist", k_hist, 3000000}, {"k_dotd", k_dotd, 1000000}, {"k_lcs", k_lcs, 600},
        {"k_lsum", k_lsum, 1000000}, {"k_lfor", k_lfor, 1000000}, {"k_lset", k_lset, 1000000}, {"k_dict", k_dict, 1000000}, {"k_str", k_str, 1000000} };
    for (unsigned i = 0; i < sizeof c / sizeof c[0]; i++) {
        double best = 1e30; long r = 0;
        for (int k = 0; k < 3; k++) { double t0 = now(); r = c[i].f(c[i].arg); double t = now() - t0; if (t < best) best = t; }
        printf("%s %ld %.3f\n", c[i].nm, r, best);
    }
    return 0;
}
