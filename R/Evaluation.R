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
Gordon.T <- function(DSP,DSP_n,r,g){
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
#' PE.T(DSP,DSP_n,r,g)
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

### 经济增加值折现法
#' EVA.G
#' @description 公司运用资本所创造的高于资本成本的价值，它等于投入资本回报率ROIC
#' 与资本成本WACC之差乘以投入成本IC，根据Gordon永续增长模型计算
#' @param IC0, 投入成本
#' @param EVA, 从第一年到第n每年资本增加值
#' @param WACC, 资本成本
#' @param ROIC, 投入资本回报率
#' @param NOPLAT, n年税后净利润
#' @param g，增长率
#' @examples
#' IC0 = 10
#' EVA = c(1,2,3,4)
#' WACC = 0.1
#' NOPLAT = 6
#' ROIC = 0.15
#' g = 0.03
#' EVA.G(IC0,EVA,WACC,NOPLAT,ROIC,g)
#' @return P, 终值
#' @examples
#' 
#' @export
EVA.G <- function(IC0,EVA,WACC,NOPLAT,ROIC,g){
  P <- IC0
  for(i in seq_along(EVA)){
    P <- P + EVA[i]/((1+WACC)^i)
  }
  n <- length(EVA)
  P_n <- NOPLAT * (1 + g) * (ROIC - WACC)/((WACC - g) * ROIC * (1 + WACC)^n)
  P <- P + P_n
  return(P)
}

#' EVA.T
#' @description 公司运用资本所创造的高于资本成本的价值，它等于投入资本回报率ROIC
#' 与资本成本WACC之差乘以投入成本IC，根据Gordon永续增长模型计算
#' @param IC0, 投入成本
#' @param EVA, 从第一年到第n每年资本增加值
#' @param WACC, 资本成本
#' @param IC_n, 第n年投入资本
#' @param EBITDA, 第n年息税折旧摊销前利润
#' @param M，EV/EBITDA 退出倍数
#' @return P, 终值
#' @examples
#' IC0 = 10
#' EVA = c(1,2,3,4)
#' WACC = 0.1
#' IC_n = 2
#' EBITDA = 6
#' M = 2
#' EVA.T(IC0,EVA,WACC,IC_n,EBITDA,M)
#' @export
EVA.T <- function(IC0,EVA,WACC,IC_n,EBITDA,M){
  P <- IC0
  for(i in seq_along(EVA)){
    P <- P + EVA[i]/((1+WACC)^i)
  }
  n <- length(EVA)
  P_n <- (EBITDA * M - IC_n) / ((1 + WACC)^n)
  P <- P + P_n
  return(P)
}