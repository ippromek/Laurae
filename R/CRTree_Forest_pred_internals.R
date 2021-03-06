#' Complete-Random Tree Forest Predictor (Deferred predictor) implementation in R
#'
#' This function attempts to predict from Complete-Random Tree Forests using xgboost. Requesting predictions form \code{CRTreeForest} should be done using \code{CRTreeForest_pred}.
#' 
#' For implementation details of Cascade Forest / Complete-Random Tree Forest / Multi-Grained Scanning / Deep Forest, check this: \url{https://github.com/Microsoft/LightGBM/issues/331#issuecomment-283942390} by Laurae.
#' 
#' @param model Type: list. A model trained by \code{CRTreeForest}.
#' @param data Type: data.table. A data to predict on. If passing training data, it will predict as if it was out of fold and you will overfit (so, use the list \code{train_preds} instead please).
#' @param folds Type: list. The folds as list for cross-validation if using the training data. Otherwise, leave \code{NULL}. Defaults to \code{NULL}.
#' @param prediction Type: logical. Whether the predictions of the forest ensemble are averaged. Set it to \code{FALSE} for debugging / feature engineering. Setting it to \code{TRUE} overrides \code{return_list}. Defaults to \code{FALSE}.
#' @param multi_class Type: numeric. How many classes you got. Set to 2 for binary classification, or regression cases. Set to \code{NULL} to let it try guessing by reading the \code{model}. Defaults to \code{NULL}.
#' @param data_start Type: vector of numeric. The initial prediction labels. Set to \code{NULL} if you do not know what you are doing. Defaults to \code{NULL}.
#' @param return_list Type: logical. Whether lists should be returned instead of concatenated frames for predictions. Defaults to \code{TRUE}.
#' 
#' @return A data.table or a list based on \code{data} predicted using \code{model}.
#' 
#' @export

CRTree_Forest_pred_internals <- function(model,
                                         data,
                                         folds = NULL,
                                         prediction = FALSE,
                                         multi_class = NULL,
                                         data_start = NULL,
                                         return_list = TRUE) {
  
  preds <- list()
  
  # Do predictions
  for (i in 1:length(model$model)) {
    
    # Are we doing multiclass?
    if (multi_class > 2) {
      preds[[i]] <- data.table(matrix(rep(0, nrow(data) * multi_class), nrow = nrow(data), ncol = multi_class))
    } else {
      preds[[i]] <- numeric(nrow(data))
    }
    
    # Column sampling by checking whether to copy or not
    if (length(model$features[[i]]) != ncol(data)) {
      new_data <- Laurae::DTcolsample(data, model$features[[i]])
    } else {
      new_data <- copy(data)
    }
    
    # Are we predicting cross-validated training data or new data?
    if (is.null(folds)) {
      
      # Convert to xgb.DMatrix
      new_data <- xgb.DMatrix(data = Laurae::DT2mat(new_data), base_margin = data_start)
      
      for (j in 1:length(model$model[[i]])) {
        # Make predictions
        preds[[i]] <- (predict(model$model[[i]][[j]], new_data, reshape = TRUE) / length(model$folds)) + preds[[i]]
      }
      
    } else {
      
      # Check whether we are doing multiclass or not
      
      if (multi_class > 2) {
        
        for (j in 1:length(model$model[[i]])) {
          
          # Convert to xgb.DMatrix
          new_data_sub <- xgb.DMatrix(data = Laurae::DT2mat(Laurae::DTsubsample(new_data, folds[[j]])), base_margin = data_start[folds[[j]]])
          
          # Make predictions
          preds[[i]][folds[[j]]] <- data.table(predict(model$model[[i]][[j]], new_data_sub, reshape = TRUE))
          
        }
        
      } else {
        
        for (j in 1:length(model$model[[i]])) {
          
          # Convert to xgb.DMatrix
          new_data_sub <- xgb.DMatrix(data = Laurae::DT2mat(Laurae::DTsubsample(new_data, folds[[j]])), base_margin = data_start[folds[[j]]])
          
          # Make predictions
          preds[[i]][folds[[j]]] <- predict(model$model[[i]][[j]], new_data_sub, reshape = TRUE)
          
        }
        
      }
      
    }
    
  }
  
  # Rename columns
  names(preds) <- paste0("Forest_", sprintf(paste0("%0", floor(log10(length(model$model))) + 1, "d"), 1:length(model$model)))
  
  # Do we want data.tables instead of lists?
  if ((return_list == FALSE) | (prediction == TRUE)) {
    
    # Is the problem a multiclass problem? (exports list of data.table instead of list of vector)
    if (multi_class > 2) {
      
      # Rename each column
      for (i in 1:length(model$model)) {
        colnames(preds[[i]]) <- paste0("Forest_", sprintf(paste0("%0", floor(log10(length(model$model))) + 1, "d"), i), "_", sprintf(paste0("%0", floor(log10(ncol(preds[[i]]))) + 1, "d"), 1:ncol(preds[[i]])))
      }
      
      train_dt <- preds[[1]]
      
      # Do we have more than one model in forest?
      if (length(model$model) > 1) {
        
        # Attempt to bind each data.table together
        for (i in 2:length(model$model)) {
          train_dt <- Laurae::DTcbind(train_dt, preds[[i]])
        }
      }
      
      if (prediction == TRUE) {
        
        # Create fresh table
        preds <- data.table(matrix(rep(0, nrow(data) * multi_class), nrow = nrow(data), ncol = multi_class))
        colnames(preds) <- paste0("Label_", sprintf(paste0("%0", floor(log10(multi_class)) + 1, "d"), 1:multi_class))
        
        # Get predictions
        for (j in 1:multi_class) {
          preds[[j]] <- rowMeans(train_dt[, (0:(length(model$model) - 1)) * multi_class + j, with = FALSE])
        }
        
      } else {
        
        # Table to return
        preds <- train_dt
        
      }
      
    } else {
      
      # Only vectors, so we can cbindlist directly
      preds <- Laurae::cbindlist(preds)
      
      if (prediction == TRUE) {
        
        # Get predictions
        preds <- rowMeans(preds)
        
      }
      
    }
    
  }
  
  # # Are we averaging? a.k.a prediction code
  # if (average == TRUE) {
  #   
  #   if (multi_class > 2) {
  #     
  #     # Prepare for multiclass problems
  #     my_preds <- data.table(matrix(rep(0, nrow(data) * multi_class), nrow = nrow(data), ncol = multi_class))
  #     colnames(my_preds) <- paste0("Label_", sprintf(paste0("%0", floor(log10(multi_class)) + 1, "d"), 1:multi_class))
  #     
  #     for (i in 1:multi_class) {
  #       my_preds[[i]] <- rowMeans(preds[, (0:(length(model$model) - 1)) * multi_class + i, with = FALSE])
  #     }
  #     
  #     # Give back hand to user
  #     return(my_preds)
  #     
  #   } else {
  #     
  #     # Take mean of all predictions by row
  #     preds <- rowMeans(preds)
  #     
  #     # Give back hand to user
  #     return(preds)
  #     
  #   }
  #   
  # }
  
  return(preds)
  
}
