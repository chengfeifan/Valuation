# 绝对估值方法

## 终值估算模型

### Gordon永续模型
#' Gordon
#' @description 终值计算根据Gordon永续增长模型，Gordon永续增长模型的假设是：
#' 公司的净利润按照稳定的增长率（g）进行增长，公司的红利也按照每年(g)进行增长
#' @param DSP, 第一年到第n-1发放红利的数额
#' @param DSP_n, 第n年发放的红利数额
#' @param r, 与红利匹配的折现率
#' @param g, 增长率
#' @return P, 终值
#' @examples
#' DSP = c(1,2,3,4)
#' DSP_n = 5
#' r = 0.1
#' g = 0.03
#' Gordon(DSP,DSP_n,r,g)
#' @export
Gordon <- function(DSP,DSP_n,r,g){
  P <- 0
  for(i in seq_along(DSP)){
    P <- P + DSP[i]/((1+r)^i)
  }
  n <- length(DSP) + 1
  P_n <- DSP_n*(1+g)/(r-g)
  P <- P + P_n/((1+r)^n)
  return(P)
}

### 终值倍数法
#' PE.T
#' @description 终值计算根据期末的相关倍数进行预测，以市盈率PE和每股盈利EPS进行计算
#' @param DSP, 第一年到第n发放红利的数额
#' @param EPS, 第n年每股盈利率
#' @param r, 与红利匹配的折现率
#' @param PE, 市盈率
#' @return P, 终值
#' @examples
#' DSP = c(1,2,3,4)
#' EPS = 5
#' r = 0.1
#' PE = 0.03
#' Gordon(DSP,DSP_n,r,g)
#' @export
PE.T <- function(DSP,EPS,r,PE){
  P <- 0
  for(i in seq_along(DSP)){
    P <- P + DSP[i]/((1+r)^i)
  }
  n <- length(DSP)
  P_n <- PE * EPS
  P <- P + P_n/((1+r)^n)
  return(P)
}
