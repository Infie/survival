# Automatically generated from the noweb directory
docurve2 <- function(entry, etime, status, istate, wt, states, id, 
                     se.fit, influence=FALSE) {
    timeset <- sort(unique(etime))
    nstate <- length(states)
    uid <- sort(unique(id))
    index <- match(id, uid)
    first <- match(uid, id)  # first row for each subject
    cstate <- istate[first]

    # The influence matrix can be huge, make sure we have enough memory
    if (influence) {
        needed <- nstate * (1.0 + length(timeset)) * length(first)
        if (needed > .Machine$integer.max)
            stop("length of the influence matrix is > the maximum integer")
    }
    storage.mode(wt) <- "double" # just in case someone had integer weights
    # Compute p0
    if (all(status==0))  t0 <- max(etime)  #failsafe
    else t0 <- min(etime[status!=0])  # first transition event
    at.zero <- (entry < t0 & etime >= t0) 
    wtsum <- sum(wt[at.zero])  # weights for a subject may change
    p0 <- tapply(wt[at.zero], factor(istate[at.zero], levels=states), sum) /
          wtsum
    p0 <- ifelse(is.na(p0), 0, p0)  #for a state not in at.zero, tapply gives NA

    # initial leverage matrix
    nid <- length(uid)
    i0  <- matrix(0., nid, nstate)
    if (all(p0 <1)) {  #actually have to compute it
        who <- index[at.zero]  # this will have no duplicates
        for (j in 1:nstate) 
            i0[who,j] <- (ifelse(istate[at.zero]==j, 1, 0) - p0[j])/wtsum
    }
     
    storage.mode(cstate) <- "integer"
    storage.mode(status) <- "integer"
    # C code has 0 based subscripts
    if (influence) se.fit <- TRUE   # se.fit is free in this case
    fit <- .Call(Csurvfitci, c(entry, etime), 
                 order(entry) - 1L,
                 order(etime) - 1L,
                 length(timeset),
                 status,
                 cstate - 1L,
                 wt,
                 index -1L,
                 p0, i0,
                 as.integer(se.fit) + 2L*as.integer(influence))
    if (se.fit) 
        out <- list(n=length(etime), time= timeset, p0 = p0,
                    sp0= sqrt(colSums(i0^2)),
             pstate = fit$p, std.err=fit$std,
             n.risk = fit$nrisk,
             n.event= fit$nevent,
             n.censor=fit$ncensor,
             cumhaz=array(fit$cumhaz, dim=c(nstate, nstate, length(timeset))))
    else out <- list(n=length(etime), time= timeset, p0=p0,
             pstate = fit$p,
             n.risk = fit$nrisk, 
             n.event = fit$nevent, 
             n.censor= fit$ncensor, 
             cumhaz=array(fit$cumhaz, dim=c(nstate, nstate, length(timeset))))
    if (influence) {
        temp <-  array(fit$influence, 
                       dim=c(length(uid), nstate, 1+ length(timeset)),
                       dimnames=list(uid, NULL, NULL))
        out$influence <- aperm(temp, c(1,3,2))
    }
    out
}
survfitCI <- function(X, Y, weights, id, istate, 
                      type=c('kaplan-meier', 'fleming-harrington', 'fh2'),
                      se.fit=TRUE,
                      conf.int= .95,
                      conf.type=c('log',  'log-log',  'plain', 'none'),
                      conf.lower=c('usual', 'peto', 'modified'),
                      influence = FALSE){

    method <- match.arg(type)
#    error <- match.arg(error)
#    if (error != "inf")
#        warning("Only the infinetesimal jackknife error is supported for CI curves")
    conf.type <- match.arg(conf.type)
    conf.lower<- match.arg(conf.lower)
    if (is.logical(conf.int)) {
        # A common error is for users to use "conf.int = FALSE"
        #  it's illegal per documentation, but be kind
        if (!conf.int) conf.type <- "none"
        conf.int <- .95
    }

    type <- attr(Y, "type")
    # This line should be unreachable, unless they call "surfitCI"
    if (type !='mright' && type!='mcounting')
         stop(paste("multi-state computation doesn't support \"", type,
                          "\" survival data", sep=''))

    n <- nrow(Y)
    status <- Y[,ncol(Y)]
    ncurve <- length(levels(X))
    
    state.names <- attr(Y, "states")
    nstate <- length(state.names) 
    has.istate <- !missing(istate)
    if (missing(istate) || is.null(istate)) {
        istate <- rep(nstate+ 1L, n)
        state.names <- c(state.names, "")
        }
    else {
        if (is.factor(istate) || is.character(istate)) {
            # Match levels with the survival variable
            temp <- as.factor(istate)
            # append any starting states not found in Y, but remember that
            #  if istate was a factor then not all its levels might appear
            appear <- (levels(temp))[unique(as.numeric(temp))]
            state.names <- unique(c(attr(Y, "states"), appear))
            istate <- as.numeric(factor(as.character(temp), levels=state.names))
        }
        else {
            if (!is.numeric(istate) || any(istate != floor(istate)) || 
                any(istate < 1))
                stop("istate should be a vector of integers or a factor")
            if (max(istate) > nstate) 
                state.names <- c(state.names, (1+nstate):max(istate))
        }
    }  
    if (length(id) ==0) id <- 1:n
    # these next two lines should be impossible, since istate came from 
    #   the data frame
    if (length(istate) ==1) istate <- rep(istate,n)
    if (length(istate) !=n) stop ("wrong length for istate")

    # The states of the status variable are the first columns in the output
    states <- unique(c(1:nstate, istate))
    curves <- vector("list", ncurve)
    names(curves) <- levels(X)
                            
    if (ncol(Y)==2) {  # 1 transition per subject
        indx <- which(status == istate & status!=0)
        if (length(indx)) {
            warning("an observation transitions to it's starting state, transition ignored")
            status[indx] <- 0
        }
        if (length(id) && any(duplicated(id)))
            stop("Cannot have duplicate id values with (time, status) data")

        # make a table of transitions.  Variable 'from' can range across
        #  all of the states, 'to' can only have nstate categories
        nst <- length(state.names)
        transitions <- table(factor(istate, 1:nst), factor(Y[,2], 1:nstate))
        dimnames(transitions) <-list(from=state.names, to=state.names[1:nstate])
                             
        # dummy entry time that is < any event time
        t0 <- min(0, Y[,1])
        entry <- rep(t0-1, nrow(Y))
        for (i in levels(X)) {
            indx <- which(X==i)
            curves[[i]] <- docurve2(entry[indx], Y[indx,1], status[indx], 
                                    istate[indx], weights[indx], states, 
                                    id[indx], se.fit)
         }
    }
    else {
        if (missing(id) || is.null(id))
            stop("the id argument is required for start:stop data")

        indx <- order(id, Y[,2])  #ordered event times within subject
        indx1 <- indx[-length(indx)]  #a pair of lagged indices
        indx2 <- indx[-1]
        #if indx1[5] == index2[5] that means that the 5th and 6th are the same id
        same <- (id[indx1] == id[indx2])
        if (any(same & X[indx1] != X[indx2])) {
            who <- min(which(same & X[indx1] != X[indx2]))
            stop("subject is in two different groups, id ", id[indx1[who]])
        }
        if (any(same & Y[indx1,2] != Y[indx2,1])) {
            who <- min(which(same & Y[indx1,2] != Y[indx2,1]))
            stop("gap in follow-up, id ", id[indx1[who]])
        }
        if (any(Y[,1] == Y[,2])) 
            stop("cannot have start time == stop time")

        if (any(same & (Y[indx1,3] == Y[indx2,3]) & (Y[indx1,3] !=0))) {
            who <-  min(which(same & (Y[indx1,3] == Y[indx2,3]) & (Y[indx1,3] !=0)))
            warning("subject changes to the same state, id ", id[indx1[who]])
        }

        # Make the table of transitions
        nst <- length(state.names)
        first <- indx[!duplicated(id[indx])]
        transitions <- table(factor(istate[first], 1:nst), 
                             factor(Y[first,3], 1:nstate))
        if (any(same))
            transitions <- transitions + table(factor(Y[indx1[same],3], 1:nst),
                                               factor(Y[indx2[same],3], 1:nstate))
        dimnames(transitions) = list(from=state.names, to=state.names[1:nstate])
        # We only want to pay attention to the istate variable for the very first
        #  observation of any given subject, but the program logic does better with
        #  a full one.  So construct one that will do this
        indx <- order(Y[,2])
        uid <- unique(id)
        temp <- (istate[indx])[match(uid, id[indx])]  #first istate for each subject
        istate <- temp[match(id, uid)]  #replicate it to full length

        # Now to work
        for (i in levels(X)) {
            indx <- which(X==i)
        #    temp <- docurve1(Y[indx,1], Y[indx,2], status[indx], 
        #                          istate[indx], weights[indx], states, id[indx])
            curves[[i]] <- docurve2(Y[indx,1], Y[indx,2], status[indx], istate[indx],
                                  weights[indx], states, id[indx], se.fit, influence)
        }
    }

    # Turn the result into a survfit type object
    grabit <- function(clist, element) {
        temp <-(clist[[1]][[element]]) 
        if (is.matrix(temp)) {
            do.call("rbind", lapply(clist, function(x) x[[element]]))
            }
        else {
            xx <- as.vector(unlist(lapply(clist, function(x) x[element])))
            if (class(temp)=="table") matrix(xx, byrow=T, ncol=length(temp))
            else xx
        }
    }
    if (length(curves) ==1) {
        keep <- c("n", "time", "n.risk", "n.event", "n.censor", "pstate",
                  "p0", "cumhaz", "influence")
        if (se.fit) keep <- c(keep, "std.err", "sp0")
        kfit <- (curves[[1]])[match(keep, names(curves[[1]]), nomatch=0)]
        names(kfit$p0) <- state.names
    }
    else {    
        kfit <- list(n =      as.vector(table(X)),  #give it labels
                     time =   grabit(curves, "time"),
                     n.risk=  grabit(curves, "n.risk"),
                     n.event= grabit(curves, "n.event"),
                     n.censor=grabit(curves, "n.censor"),
                     pstate = grabit(curves, "pstate"),
                     p0     = grabit(curves, "p0"),
                     transitions = transitions,
                     strata= unlist(lapply(curves, function(x) length(x$time))))
        kfit$p0 <- matrix(kfit$p0, ncol=nst, byrow=TRUE,
                          dimnames=list(names(curves), state.names))
        if (se.fit) {
            kfit$std.err <- grabit(curves, "std.err")
            kfit$sp0<- matrix(grabit(curves, "sp0"),
                              ncol=nst, byrow=TRUE)
        }
        kfit$cumhaz <- array(unlist(lapply(curves, function(x) x$cumhaz)),
                               dim=c(nstate, nstate, length(kfit$time)))
        if (influence) kfit$influence <- lapply(curves, function(x) x$influence)
    }                         
    kfit$transitions <- transitions
    #       
    # Last bit: add in the confidence bands:
    #   modeled on survfit.km, though for P instead of S
    #   
    #
    if (se.fit) {
        std.err <- kfit$std.err
        zval <- qnorm(1- (1-conf.int)/2, 0,1)

        if (conf.type=='plain') {
            temp <- zval* kfit$std.err
            kfit <- c(kfit, list(lower =pmax(kfit$pstate-temp, 0), 
                                 upper=pmin(kfit$pstate+temp, 1),
                             conf.type='plain', conf.int=conf.int))
            }

        if (conf.type=='log') {
            #avoid some "log(0)" messages
            xx <- ifelse(kfit$pstate==1, 1, 1- kfit$pstate)  

            temp1 <- ifelse(kfit$pstate==1, NA, exp(log(xx) + zval* kfit$std.err/xx))
            temp2 <- ifelse(kfit$pstate==1, NA, exp(log(xx) - zval* kfit$std.err/xx))
            kfit <- c(kfit, list(lower=pmax(1-temp1,0), upper= 1- temp2,
                             conf.type='log', conf.int=conf.int))
            }

        if (conf.type=='log-log') {
            who <- (kfit$pstate==0 | kfit$pstate==1) #special cases
            temp3 <- ifelse(kfit$pstate==1, NA, 1)
            xx <- ifelse(who, .1,kfit$pstate)  #avoid some "log(0)" messages
            temp1 <- exp(-exp(log(-log(xx)) + zval*kfit$std.err/(xx*log(xx))))
            temp1 <- ifelse(who, temp3, temp1)
            temp2 <- exp(-exp(log(-log(xx)) - zval*kfit$std.err/(xx*log(xx))))
            temp2 <- ifelse(who, temp3, temp2)
            kfit <- c(kfit, list(lower=1-temp1, upper=1-temp2,
                             conf.type='log-log', conf.int=conf.int))
            }
        }

    kfit$states <- state.names
    kfit$type   <- attr(Y, "type")
    kfit
}
