public class MatrixConfigurationQueueable implements Queueable {
    private String matrixVersionId;
    private List<CsvDataController.ColumnConfiguration> columnConfigurations;
    private vlocity_ins__CalculationMatrixVersion__c matrixVersion;
    private Integer batchSize = 50;
    private Integer offset = 0;
    
    public MatrixConfigurationQueueable(String matrixVersionId, List<CsvDataController.ColumnConfiguration> columnConfigurations, vlocity_ins__CalculationMatrixVersion__c matrixVersion) {
        this.matrixVersionId = matrixVersionId;
        this.columnConfigurations = columnConfigurations;
        this.matrixVersion = matrixVersion;
    }
    
    public MatrixConfigurationQueueable(String matrixVersionId, List<CsvDataController.ColumnConfiguration> columnConfigurations, vlocity_ins__CalculationMatrixVersion__c matrixVersion, Integer offset) {
        this(matrixVersionId, columnConfigurations, matrixVersion);
        this.offset = offset;
    }
    
    public void execute(QueueableContext context) {
        try {
            // Process batch
            Map<String, CsvDataController.ColumnConfiguration> configMap = new Map<String, CsvDataController.ColumnConfiguration>();
            for (CsvDataController.ColumnConfiguration config : columnConfigurations) {
                configMap.put(config.columnName, config);
            }
            
            // Get batch of rows
            List<vlocity_ins__CalculationMatrixRow__c> rows = [
                SELECT Id, vlocity_ins__InputData__c 
                FROM vlocity_ins__CalculationMatrixRow__c 
                WHERE vlocity_ins__CalculationMatrixVersionId__c = :matrixVersionId
                ORDER BY Id
                LIMIT :batchSize 
                OFFSET :offset
            ];
            
            if (!rows.isEmpty()) {
                // Process this batch
                List<vlocity_ins__CalculationMatrixRow__c> rowsToUpdate = new List<vlocity_ins__CalculationMatrixRow__c>();
                
                for (vlocity_ins__CalculationMatrixRow__c row : rows) {
                    if (String.isNotBlank(row.vlocity_ins__InputData__c)) {
                        Map<String, Object> inputData = (Map<String, Object>) JSON.deserializeUntyped(row.vlocity_ins__InputData__c);
                        Map<String, Object> newInputData = new Map<String, Object>();
                        Map<String, Object> newOutputData = new Map<String, Object>();
                        
                        for (String columnName : inputData.keySet()) {
                            CsvDataController.ColumnConfiguration config = configMap.get(columnName);
                            Object value = inputData.get(columnName);
                            
                            if (config != null) {
                                if (config.headerType == 'Input') {
                                    newInputData.put(columnName, value);
                                } else {
                                    newOutputData.put(columnName, value);
                                }
                            } else {
                                newInputData.put(columnName, value);
                            }
                        }
                        
                        row.vlocity_ins__InputData__c = JSON.serialize(newInputData);
                        row.vlocity_ins__OutputData__c = JSON.serialize(newOutputData);
                        rowsToUpdate.add(row);
                    }
                }
                
                if (!rowsToUpdate.isEmpty()) {
                    update rowsToUpdate;
                }
                
                // Chain next batch if more records exist
                if (rows.size() == batchSize) {
                    MatrixConfigurationQueueable nextJob = new MatrixConfigurationQueueable(
                        matrixVersionId, columnConfigurations, matrixVersion, offset + batchSize
                    );
                    System.enqueueJob(nextJob);
                } else {
                    // Last batch - update matrix version status
                    finalizeBatchProcessing();
                }
            } else {
                // No more records - finalize
                finalizeBatchProcessing();
            }
            
        } catch (Exception e) {
            System.debug('Error in batch processing: ' + e.getMessage());
            // Send notification of failure
        }
    }
    
    private void finalizeBatchProcessing() {
        try {
            // Update matrix version status
            Integer versionNumber = matrixVersion.vlocity_ins__VersionNumber__c != null ? 
                Integer.valueOf(matrixVersion.vlocity_ins__VersionNumber__c) : 1;
            
            List<vlocity_ins__CalculationMatrixVersion__c> versionsToUpdate = [
                SELECT Id, vlocity_ins__IsEnabled__c, vlocity_ins__Priority__c
                FROM vlocity_ins__CalculationMatrixVersion__c
                WHERE vlocity_ins__CalculationMatrixId__c = :matrixVersion.vlocity_ins__CalculationMatrixId__c
            ];
            
            for (vlocity_ins__CalculationMatrixVersion__c version : versionsToUpdate) {
                if (version.Id == matrixVersion.Id) {
                    version.vlocity_ins__IsEnabled__c = true;
                    version.vlocity_ins__Priority__c = versionNumber;
                } else {
                    version.vlocity_ins__IsEnabled__c = false;
                }
            }
            
            update versionsToUpdate;
            
            // Send success notification
            System.debug('Matrix configuration completed successfully');
            
        } catch (Exception e) {
            System.debug('Error finalizing batch processing: ' + e.getMessage());
        }
    }
}