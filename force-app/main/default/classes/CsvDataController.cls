/**
 * @description Controller class for CSV data upload to Vlocity Calculation Matrix and paginated display
 * @author Salesforce Developer
 */
public with sharing class CsvDataController {
    // Constants for pagination
    public static final Integer DEFAULT_PAGE_SIZE = 50;
    public static final Integer MAX_FILE_SIZE = 5 * 1024 * 1024; // 5MB
    /**
     * @description Get or create calculation matrix (reuse existing if found)
     * @param matrixName Name for the calculation matrix
     * @return String CalculationMatrix ID
     */
    private static String getOrCreateCalculationMatrix(String matrixName) {
        try {
            // Use the matrix name as-is (without adding '_Matrix' suffix)
            String matrixNameToSearch = matrixName;
            
            // Check if matrix with this name already exists
            List<vlocity_ins__CalculationMatrix__c> existingMatrices = [
                SELECT Id FROM vlocity_ins__CalculationMatrix__c 
                WHERE Name = :matrixNameToSearch
                LIMIT 1
            ];
            // If matrix exists, return its ID
            if (!existingMatrices.isEmpty()) {
                return existingMatrices[0].Id;
            }
            // Create new matrix
            vlocity_ins__CalculationMatrix__c matrix = new vlocity_ins__CalculationMatrix__c();
            matrix.Name = matrixNameToSearch;
            insert matrix;
            return matrix.Id;
        } catch (Exception e) {
            throw new AuraHandledException('Error creating calculation matrix: ' + e.getMessage());
        }
    }
    /**
     * @description Get next available version number with conflict resolution
     * @param calculationMatrixId ID of the calculation matrix
     * @return Integer Next available version number
     */
    private static Integer getNextAvailableVersionNumber(String calculationMatrixId) {
        try {
            System.debug('==== DEBUG: Getting next version for matrix ID: ' + calculationMatrixId);
            // Get ALL existing version numbers for this matrix
            List<vlocity_ins__CalculationMatrixVersion__c> existingVersions = [
                SELECT vlocity_ins__VersionNumber__c
                FROM vlocity_ins__CalculationMatrixVersion__c 
                WHERE vlocity_ins__CalculationMatrixId__c = :calculationMatrixId
                ORDER BY vlocity_ins__VersionNumber__c ASC
            ];
            
            System.debug('==== DEBUG: All existing versions: ' + existingVersions);
            
            // If no versions exist, start with 1
            if (existingVersions.isEmpty()) {
                System.debug('==== DEBUG: No existing versions, returning 1');
                return 1;
            }
            // Create a set of existing version numbers
            Set<Integer> existingVersionNumbers = new Set<Integer>();
            for (vlocity_ins__CalculationMatrixVersion__c version : existingVersions) {
                if (version.vlocity_ins__VersionNumber__c != null) {
                    existingVersionNumbers.add((Integer) version.vlocity_ins__VersionNumber__c);
                }
            }
            
            System.debug('==== DEBUG: Existing version numbers: ' + existingVersionNumbers);
            
            // Find the first available version number starting from 1
            Integer nextVersion = 1;
            while (existingVersionNumbers.contains(nextVersion)) {
                nextVersion++;
            }
            System.debug('==== DEBUG: Next available version: ' + nextVersion);
            return nextVersion;
            
        } catch (Exception e) {
            System.debug('==== DEBUG: Error getting version number: ' + e.getMessage());
            return 1;
        }
    }
    
    /**
     * @description Get paginated CSV data from Calculation Matrix Version
     * @param matrixVersionId ID of the CalculationMatrixVersion
     * @param pageNumber Current page number (1-based)
     * @param pageSize Number of records per page
     * @return CsvDataResponse Wrapper containing data and pagination info
     */
    @AuraEnabled(cacheable=false)
    public static CsvDataResponse getMatrixCsvData(String matrixVersionId, Integer pageNumber, Integer pageSize) {
        try {
            if (pageSize == null || pageSize <= 0) {
                pageSize = DEFAULT_PAGE_SIZE;
            }
            
            if (pageNumber == null || pageNumber <= 0) {
                pageNumber = 1;
            }
            
            // Get the matrix version record
            vlocity_ins__CalculationMatrixVersion__c matrixVersion = [
                SELECT Id, Name, vlocity_ins__VersionNumber__c, vlocity_ins__CalculationMatrixId__c,
                       vlocity_ins__IsEnabled__c, vlocity_ins__StartDateTime__c, vlocity_ins__EndDateTime__c
                FROM vlocity_ins__CalculationMatrixVersion__c 
                WHERE Id = :matrixVersionId 
                LIMIT 1
            ];
            
            // Get CSV data from CalculationMatrixRow records
            List<vlocity_ins__CalculationMatrixRow__c> allRows = [
                SELECT Id, Name, vlocity_ins__InputData__c, vlocity_ins__OutputData__c
                FROM vlocity_ins__CalculationMatrixRow__c 
                WHERE vlocity_ins__CalculationMatrixVersionId__c = :matrixVersionId
                ORDER BY Name ASC
            ];
            
            // Parse stored CSV data from first row's InputData or reconstruct from rows
            List<List<String>> parsedCsv = reconstructCsvFromRows(allRows);
            
            if (parsedCsv.isEmpty()) {
                throw new AuraHandledException('No data found in calculation matrix version.');
            }
            // Extract headers and data
            List<String> headers = parsedCsv[0];
            List<List<String>> allDataRows = new List<List<String>>();
            // Skip header row
            for (Integer i = 1; i < parsedCsv.size(); i++) {
                allDataRows.add(parsedCsv[i]);
            }
            // Calculate pagination
            Integer totalRecords = allDataRows.size();
            Integer totalPages = totalRecords > 0 ? (Integer) Math.ceil((Decimal) totalRecords / pageSize) : 0;
            Integer startIndex = (pageNumber - 1) * pageSize;
            Integer endIndex = Math.min(startIndex + pageSize, totalRecords);
            
            // Get current page data
            List<List<String>> pageData = new List<List<String>>();
            for (Integer i = startIndex; i < endIndex; i++) {
                if (i < allDataRows.size()) {
                    pageData.add(allDataRows[i]);
                }
            }
            
            // Convert to map format for Lightning Data Table
            List<Map<String, Object>> records = convertToRecords(headers, pageData, startIndex);
            
            // Create response
            CsvDataResponse response = new CsvDataResponse();
            response.records = records;
            response.headers = headers;
            response.totalRecords = totalRecords;
            response.currentPage = pageNumber;
            response.pageSize = pageSize;
            response.totalPages = totalPages;
            response.hasNext = pageNumber < totalPages;
            response.hasPrevious = pageNumber > 1;
            response.fileName = matrixVersion.Name + '_v' + matrixVersion.vlocity_ins__VersionNumber__c + '.csv';
            response.matrixVersionId = matrixVersionId;
            response.isEnabled = matrixVersion.vlocity_ins__IsEnabled__c;
            
            return response;
            
        } catch (Exception e) {
            System.debug('Error in getMatrixCsvData: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error retrieving matrix CSV data: ' + e.getMessage());
        }
    }
    
    /**
     * @description Search CSV data across all records in a matrix version
     * @param matrixVersionId ID of the CalculationMatrixVersion
     * @param searchTerm Search term to filter data
     * @param pageNumber Current page number (1-based)
     * @param pageSize Number of records per page
     * @return CsvDataResponse Wrapper containing filtered data and pagination info
     */
    @AuraEnabled
    public static String saveMatrixVersion(String fileName, String fileContent, String matrixName, String calculationMatrixId, List<Map<String, String>> columnConfigs) {
        try {
            // Validate file type
            if (!fileName.toLowerCase().endsWith('.csv')) {
                throw new AuraHandledException('Only CSV files are allowed.');
            }
            
            // Decode CSV content
            String csvContent = EncodingUtil.base64Decode(fileContent).toString();
            
            // Parse CSV
            List<List<String>> parsedCsv = parseCSV(csvContent);
            if (parsedCsv.isEmpty()) {
                throw new AuraHandledException('CSV file is empty or invalid.');
            }
            
            // Always create a new version for each upload
            String matrixId = calculationMatrixId;
            if (String.isBlank(matrixId)) {
                matrixId = getOrCreateCalculationMatrix(matrixName);
            }
            
            // Get the Calculation Matrix record to fetch its name
            vlocity_ins__CalculationMatrix__c calculationMatrix = [
                SELECT Id, Name
                FROM vlocity_ins__CalculationMatrix__c 
                WHERE Id = :matrixId 
                LIMIT 1
            ];
            // Always get the next available version number
            Integer nextVersion = getNextAvailableVersionNumber(matrixId);
            
            // Create version name using Calculation Matrix name + version number
            String versionName = calculationMatrix.Name + ' V' + nextVersion;
            
            // Always create a new CalculationMatrixVersion
            vlocity_ins__CalculationMatrixVersion__c matrixVersion = new vlocity_ins__CalculationMatrixVersion__c();
            matrixVersion.Name = versionName;
            matrixVersion.vlocity_ins__CalculationMatrixId__c = matrixId;
            matrixVersion.vlocity_ins__VersionNumber__c = nextVersion;
            matrixVersion.vlocity_ins__IsEnabled__c = false;
            matrixVersion.vlocity_ins__StartDateTime__c = System.now();
            matrixVersion.vlocity_ins__EndDateTime__c = System.now().addYears(1);
            matrixVersion.vlocity_ins__Priority__c = nextVersion; // Set Priority to match Version Number
            insert matrixVersion;
            System.debug('Created new CalculationMatrixVersion: ' + matrixVersion.Id);
            
            // Store CSV data in the matrix version
            storeCsvDataInMatrix(matrixVersion.Id, csvContent, parsedCsv, columnConfigs);
            
            return matrixVersion.Id;
            
        } catch (Exception e) {
            System.debug('Error in saveMatrixVersion: ' + e.getMessage());
            throw new AuraHandledException('Error saving matrix version: ' + e.getMessage());
        }
    }
    
    /**
     * @description Delete Calculation Matrix Version
     * @param matrixVersionId ID of the CalculationMatrixVersion to delete
     * @return Boolean Success status
     */
    @AuraEnabled
    public static Boolean deleteMatrixVersion(String matrixVersionId) {
        try {
            if (String.isBlank(matrixVersionId)) {
                throw new AuraHandledException('Matrix Version Id is required.');
            }
            // Delete all related rows first
            List<vlocity_ins__CalculationMatrixRow__c> rowsToDelete = [
                SELECT Id FROM vlocity_ins__CalculationMatrixRow__c
                WHERE vlocity_ins__CalculationMatrixVersionId__c = :matrixVersionId
            ];
            if (!rowsToDelete.isEmpty()) {
                delete rowsToDelete;
            }
            // Delete the matrix version
            vlocity_ins__CalculationMatrixVersion__c versionToDelete = [
                SELECT Id FROM vlocity_ins__CalculationMatrixVersion__c
                WHERE Id = :matrixVersionId LIMIT 1
            ];
            delete versionToDelete;
            return true;
        } catch (Exception e) {
            System.debug('Error deleting matrix version: ' + e.getMessage());
            throw new AuraHandledException('Error deleting matrix version: ' + e.getMessage());
        }
    }
    /**
     * @description Enable/Disable Calculation Matrix Version
     * @param matrixVersionId ID of the CalculationMatrixVersion
     * @param isEnabled Boolean flag to enable/disable
     * @return Boolean Success status
     */
    @AuraEnabled
    public static Boolean toggleMatrixVersion(String matrixVersionId, Boolean isEnabled) {
        try {
            vlocity_ins__CalculationMatrixVersion__c matrixVersion = [
                SELECT Id FROM vlocity_ins__CalculationMatrixVersion__c 
                WHERE Id = :matrixVersionId LIMIT 1
            ];
            
            matrixVersion.vlocity_ins__IsEnabled__c = isEnabled;
            update matrixVersion;
            
            return true;
        } catch (Exception e) {
            throw new AuraHandledException('Error toggling matrix version status: ' + e.getMessage());
        }
    }
    
    /**
     * @description Create a new Calculation Matrix if one doesn't exist
     * @param matrixName Name for the calculation matrix
     * @return String CalculationMatrix ID
     */
    private static String createCalculationMatrix(String matrixName) {
        try {
            vlocity_ins__CalculationMatrix__c matrix = new vlocity_ins__CalculationMatrix__c();
            matrix.Name = matrixName + '_Matrix';
            
            insert matrix;
            return matrix.Id;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error creating calculation matrix: ' + e.getMessage());
        }
    }
    
    /**
     * @description Get next version number for a calculation matrix
     * @param calculationMatrixId ID of the calculation matrix
     * @return Integer Next version number
     */
    private static Integer getNextVersionNumber(String calculationMatrixId) {
        try {
            // Get all existing version numbers for this matrix
            List<vlocity_ins__CalculationMatrixVersion__c> existingVersions = [
                SELECT vlocity_ins__VersionNumber__c
                FROM vlocity_ins__CalculationMatrixVersion__c 
                WHERE vlocity_ins__CalculationMatrixId__c = :calculationMatrixId
                ORDER BY vlocity_ins__VersionNumber__c DESC
                LIMIT 1
            ];
            
            Integer maxVersion = 0;
            if (!existingVersions.isEmpty() && existingVersions[0].vlocity_ins__VersionNumber__c != null) {
                maxVersion = (Integer) existingVersions[0].vlocity_ins__VersionNumber__c;
            }
            
            // Return next available version number
            return maxVersion + 1;
            
        } catch (Exception e) {
            // If there's an error, start with a timestamp-based version to ensure uniqueness
            return Integer.valueOf(String.valueOf(System.now().getTime()).right(6));
        }
    }
    
    /**
     * @description Store CSV data in CalculationMatrixRow records using Vlocity's expected format
     * @param matrixVersionId ID of the matrix version
     * @param csvContent Raw CSV content
     * @param parsedCsv Parsed CSV data
     */
    private static void storeCsvDataInMatrix(String matrixVersionId, String csvContent, List<List<String>> parsedCsv, 
                                        List<Map<String, String>> columnConfigs) {
        try {
            if (parsedCsv.isEmpty() || parsedCsv[0].isEmpty()) {
                throw new AuraHandledException('CSV data is empty or invalid');
            }
            
            // Get headers from first row
            List<String> headers = parsedCsv[0];
            
            // Create header records first
            List<vlocity_ins__CalculationMatrixRow__c> headerRows = new List<vlocity_ins__CalculationMatrixRow__c>();
            
            // Track which columns are inputs vs outputs based on configuration
            Map<String, String> headerTypes = new Map<String, String>();
            Map<String, String> dataTypes = new Map<String, String>();
            
            // If column configs are provided, use them; otherwise default all to Input/Text
            if (columnConfigs != null && !columnConfigs.isEmpty()) {
                for (Map<String, String> config : columnConfigs) {
                    String columnName = config.get('name');
                    headerTypes.put(columnName, config.get('headerType'));
                    dataTypes.put(columnName, config.get('dataType'));
                }
            } else {
                // Default all columns to Input and Text type
                for (String header : headers) {
                    headerTypes.put(header, 'Input');
                    dataTypes.put(header, 'Text');
                }
            }
            
            // Create a header record for each column
            Integer displayOrder = 1;
            for (String header : headers) {
                Map<String, Object> headerMetadata = new Map<String, Object>();
                headerMetadata.put('name', header);
                headerMetadata.put('headerType', headerTypes.containsKey(header) ? headerTypes.get(header) : 'Input');
                headerMetadata.put('displayOrder', displayOrder++);
                headerMetadata.put('dataType', dataTypes.containsKey(header) ? dataTypes.get(header) : 'Text');
                headerMetadata.put('columnKey', EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(header))).substring(0, 6));
                
                vlocity_ins__CalculationMatrixRow__c headerRow = new vlocity_ins__CalculationMatrixRow__c();
                headerRow.Name = 'Header';
                headerRow.vlocity_ins__CalculationMatrixVersionId__c = matrixVersionId;
                headerRow.vlocity_ins__InputData__c = JSON.serialize(headerMetadata);
                
                headerRows.add(headerRow);
            }
            
            insert headerRows;
            
            // Continue with creating data rows (existing logic)
            List<vlocity_ins__CalculationMatrixRow__c> dataRows = new List<vlocity_ins__CalculationMatrixRow__c>();
            
            // Get matrix version dates ONCE - outside the loop to avoid governor limits
            vlocity_ins__CalculationMatrixVersion__c matrixVersion = [
                SELECT vlocity_ins__StartDateTime__c, vlocity_ins__EndDateTime__c 
                FROM vlocity_ins__CalculationMatrixVersion__c 
                WHERE Id = :matrixVersionId
            ];
            
            DateTime startDateTime = matrixVersion.vlocity_ins__StartDateTime__c;
            DateTime endDateTime = matrixVersion.vlocity_ins__EndDateTime__c;
            
            // Skip header row in parsedCsv (index 0)
            for (Integer i = 1; i < parsedCsv.size(); i++) {
                List<String> dataValues = parsedCsv[i];
                
                // Skip empty rows
                if (dataValues.isEmpty()) continue;
                
                // Create maps for input and output data
                Map<String, Object> inputDataMap = new Map<String, Object>();
                Map<String, Object> outputDataMap = new Map<String, Object>();
                
                // Populate input and output maps based on header type
                for (Integer j = 0; j < headers.size() && j < dataValues.size(); j++) {
                    String header = headers[j];
                    String value = dataValues[j];
                    
                    // If header is input type, add to inputDataMap, otherwise to outputDataMap
                    if (headerTypes.get(header) == 'Input') {
                        inputDataMap.put(header, value);
                    } else {
                        outputDataMap.put(header, value);
                    }
                }
                
                // Create matrix row record
                vlocity_ins__CalculationMatrixRow__c dataRow = new vlocity_ins__CalculationMatrixRow__c();
                dataRow.vlocity_ins__CalculationMatrixVersionId__c = matrixVersionId;
                
                // Generate unique hash for row name using input data
                String inputHash = EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(JSON.serialize(inputDataMap))));
                dataRow.Name = inputHash;
                
                // Serialize maps to JSON
                dataRow.vlocity_ins__InputData__c = JSON.serialize(inputDataMap);
                dataRow.vlocity_ins__OutputData__c = JSON.serialize(outputDataMap);
                
                // Use the datetime values we already queried
                dataRow.vlocity_ins__StartDateTime__c = startDateTime;
                dataRow.vlocity_ins__EndDateTime__c = endDateTime;
                
                dataRows.add(dataRow);
            }
            
            if (!dataRows.isEmpty()) {
                insert dataRows;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error storing CSV data: ' + e.getMessage());
        }
    }
    
    /**
     * @description Reconstruct CSV data from CalculationMatrixRow records
     * @param rows List of CalculationMatrixRow records
     * @return List<List<String>> Reconstructed CSV data
     */
    private static List<List<String>> reconstructCsvFromRows(List<vlocity_ins__CalculationMatrixRow__c> rows) {
        List<List<String>> csvData = new List<List<String>>();
        if (rows.isEmpty()) return csvData;
        // Get headers from the first row's InputData__c keys
        Map<String, Object> firstRowMap = (Map<String, Object>) JSON.deserializeUntyped(rows[0].vlocity_ins__InputData__c);
        List<String> headers = new List<String>(firstRowMap.keySet());
        csvData.add(headers);
        // For each row, extract values in header order
        for (vlocity_ins__CalculationMatrixRow__c row : rows) {
            if (String.isNotBlank(row.vlocity_ins__InputData__c)) {
                try {
                    Map<String, Object> rowMap = (Map<String, Object>) JSON.deserializeUntyped(row.vlocity_ins__InputData__c);
                    List<String> rowData = new List<String>();
                    for (String header : headers) {
                        rowData.add((rowMap.containsKey(header) && rowMap.get(header) != null) ? String.valueOf(rowMap.get(header)) : '');
                    }
                    csvData.add(rowData);
                } catch (Exception e) {
                    System.debug('Error parsing row data: ' + e.getMessage());
                }
            }
        }
        return csvData;
    }
    
    /**
     * @description Parse CSV content into a list of rows
     * @param csvContent Raw CSV string content
     * @return List<List<String>> Parsed CSV data
     */
    private static List<List<String>> parseCSV(String csvContent) {
        List<List<String>> csvData = new List<List<String>>();
        
        // Split into lines and clean up
        List<String> lines = csvContent.split('\r?\n');
        
        for (String line : lines) {
            if (String.isNotBlank(line.trim())) {
                List<String> fields = parseCSVLine(line);
                csvData.add(fields);
            }
        }
        
        return csvData;
    }
    
    /**
     * @description Parse a single CSV line handling quoted fields
     * @param line CSV line to parse
     * @return List<String> List of field values
     */
    private static List<String> parseCSVLine(String line) {
        List<String> fields = new List<String>();
        Boolean inQuotes = false;
        String currentField = '';
        
        for (Integer i = 0; i < line.length(); i++) {
            String currentChar = line.substring(i, i + 1);
            
            if (currentChar == '"') {
                // Handle escaped quotes
                if (i + 1 < line.length() && line.substring(i + 1, i + 2) == '"') {
                    currentField += '"';
                    i++; // Skip next quote
                } else {
                    inQuotes = !inQuotes;
                }
            } else if (currentChar == ',' && !inQuotes) {
                fields.add(currentField.trim());
                currentField = '';
            } else {
                currentField += currentChar;
            }
        }
        
        // Add the last field
        fields.add(currentField.trim());
        
        return fields;
    }
    
    /**
     * @description Convert parsed CSV data to records for Lightning Data Table
     * @param headers List of column headers
     * @param dataRows List of data rows
     * @param startIndex Starting index for row numbering
     * @return List<Map<String, Object>> Records formatted for data table
     */
    private static List<Map<String, Object>> convertToRecords(List<String> headers, List<List<String>> dataRows, Integer startIndex) {
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        
        for (Integer i = 0; i < dataRows.size(); i++) {
            Map<String, Object> record = new Map<String, Object>();
            
            // Add row number
            record.put('rowNumber', startIndex + i + 1);
            
            List<String> row = dataRows[i];
            for (Integer j = 0; j < headers.size() && j < row.size(); j++) {
                String fieldName = sanitizeFieldName(headers[j]);
                record.put(fieldName, row[j]);
            }
            
            records.add(record);
        }
        
        return records;
    }
    
    /**
     * @description Sanitize field names for use as map keys
     * @param fieldName Original field name
     * @return String Sanitized field name
     */
    private static String sanitizeFieldName(String fieldName) {
        if (String.isBlank(fieldName)) {
            return 'Column';
        }
        
        // Remove special characters and spaces, replace with underscores
        String sanitized = fieldName.replaceAll('[^a-zA-Z0-9]', '_');
        
        // Ensure it starts with a letter
        if (!sanitized.substring(0, 1).isAlpha()) {
            sanitized = 'Col_' + sanitized;
        }
        
        return sanitized;
    }
    
    /**
     * @description Enhanced wrapper class for CSV data response with matrix info
     */
    public class CsvDataResponse {
        @AuraEnabled public List<Map<String, Object>> records { get; set; }
        @AuraEnabled public List<String> headers { get; set; }
        @AuraEnabled public Integer totalRecords { get; set; }
        @AuraEnabled public Integer currentPage { get; set; }
        @AuraEnabled public Integer pageSize { get; set; }
        @AuraEnabled public Integer totalPages { get; set; }
        @AuraEnabled public Boolean hasNext { get; set; }
        @AuraEnabled public Boolean hasPrevious { get; set; }
        @AuraEnabled public String fileName { get; set; }
        @AuraEnabled public String matrixVersionId { get; set; }
        @AuraEnabled public Boolean isEnabled { get; set; }
        @AuraEnabled public String searchTerm { get; set; } // Add this line
    }
    
    /**
     * @description Preview CSV content without creating matrix version
     * @param fileName Name of the uploaded file
     * @param fileContent Base64 encoded file content
     * @return CsvPreviewResponse Preview data and headers
     */
    @AuraEnabled
    public static CsvPreviewResponse previewCsvData(String fileName, String fileContent) {
        try {
            // Validate file type
            if (!fileName.toLowerCase().endsWith('.csv')) {
                throw new AuraHandledException('Only CSV files are allowed.');
            }
            
            // Validate file size (approximate)
            Integer fileSize = (fileContent.length() * 3) / 4; // Base64 decode size estimation
            if (fileSize > MAX_FILE_SIZE) {
                throw new AuraHandledException('File size exceeds 5MB limit.');
            }
            
            // Decode CSV content
            String csvContent = EncodingUtil.base64Decode(fileContent).toString();
            
            // Parse CSV to validate structure
            List<List<String>> parsedCsv = parseCSV(csvContent);
            if (parsedCsv.isEmpty()) {
                throw new AuraHandledException('CSV file is empty or invalid.');
            }
            
            // Extract headers and ALL data rows for preview
            List<String> headers = parsedCsv[0];
            List<List<String>> previewRows = new List<List<String>>();
            
            // Get ALL data rows for preview (exclude header)
            for (Integer i = 1; i < parsedCsv.size(); i++) {
                previewRows.add(parsedCsv[i]);
            }
            
            // Convert to records for display
            List<Map<String, Object>> previewRecords = convertToRecords(headers, previewRows, 0);
            
            // Create preview response
            CsvPreviewResponse response = new CsvPreviewResponse();
            response.headers = headers;
            response.previewRecords = previewRecords;
            response.totalDataRows = parsedCsv.size() - 1; // Exclude header
            response.fileName = fileName;
            response.isValid = true;
            
            return response;
            
        } catch (Exception e) {
            System.debug('Error in previewCsvData: ' + e.getMessage());
            
            CsvPreviewResponse errorResponse = new CsvPreviewResponse();
            errorResponse.isValid = false;
            errorResponse.errorMessage = e.getMessage();
            return errorResponse;
        }
    }
    
    /**
     * @description Wrapper class for CSV preview response
     */
    public class CsvPreviewResponse {
        @AuraEnabled public List<String> headers { get; set; }
        @AuraEnabled public List<Map<String, Object>> previewRecords { get; set; }
        @AuraEnabled public Integer totalDataRows { get; set; }
        @AuraEnabled public String fileName { get; set; }
        @AuraEnabled public Boolean isValid { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
    }
    
    /**
     * @description Get all versions for a calculation matrix
     * @param calculationMatrixId ID of the calculation matrix
     * @return List<MatrixVersionOption> List of version options for dropdown
     */
    @AuraEnabled(cacheable=true)
    public static List<MatrixVersionOption> getMatrixVersions(String calculationMatrixId) {
        try {
            List<MatrixVersionOption> versionOptions = new List<MatrixVersionOption>();
            
            if (String.isBlank(calculationMatrixId)) {
                return versionOptions;
            }
            
            List<vlocity_ins__CalculationMatrixVersion__c> versions = [
                SELECT Id, Name, vlocity_ins__VersionNumber__c, vlocity_ins__IsEnabled__c,
                       CreatedDate, LastModifiedDate
                FROM vlocity_ins__CalculationMatrixVersion__c 
                WHERE vlocity_ins__CalculationMatrixId__c = :calculationMatrixId
                ORDER BY vlocity_ins__VersionNumber__c DESC
            ];
            
            for (vlocity_ins__CalculationMatrixVersion__c version : versions) {
                MatrixVersionOption option = new MatrixVersionOption();
                option.value = version.Id;
                option.label = 'Version ' + version.vlocity_ins__VersionNumber__c + ' - ' + version.Name;
                option.versionNumber = Integer.valueOf(version.vlocity_ins__VersionNumber__c);
                option.isEnabled = version.vlocity_ins__IsEnabled__c;
                option.createdDate = version.CreatedDate;
                versionOptions.add(option);
            }
            
            return versionOptions;
            
        } catch (Exception e) {
            System.debug('Error getting matrix versions: ' + e.getMessage());
            throw new AuraHandledException('Error retrieving matrix versions: ' + e.getMessage());
        }
    }
    
    /**
     * @description Wrapper class for matrix version dropdown options
     */
    public class MatrixVersionOption {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Integer versionNumber { get; set; }
        @AuraEnabled public Boolean isEnabled { get; set; }
        @AuraEnabled public DateTime createdDate { get; set; }
    }
    
    /**
     * @description Get the name of a Calculation Matrix record
     * @param calculationMatrixId ID of the calculation matrix
     * @return String Name of the calculation matrix
     */
    @AuraEnabled(cacheable=true)
    public static String getCalculationMatrixName(String calculationMatrixId) {
        try {
            if (String.isBlank(calculationMatrixId)) {
                return null;
            }
            
            vlocity_ins__CalculationMatrix__c matrix = [
                SELECT Name
                FROM vlocity_ins__CalculationMatrix__c 
                WHERE Id = :calculationMatrixId 
                LIMIT 1
            ];
            
            return matrix.Name;
            
        } catch (Exception e) {
            System.debug('Error getting calculation matrix name: ' + e.getMessage());
            return null;
        }
    }
    
    // Add new method for updating matrix data
    @AuraEnabled
    public static String updateMatrixData(String matrixVersionId, List<Map<String, Object>> updatedRecords) {
        try {
            if (String.isBlank(matrixVersionId) || updatedRecords == null || updatedRecords.isEmpty()) {
                throw new AuraHandledException('Invalid input parameters for update.');
            }
            
            System.debug('updateMatrixData called with matrixVersionId: ' + matrixVersionId);
            System.debug('updatedRecords: ' + JSON.serializePretty(updatedRecords));
            
            // Get existing matrix rows
            List<vlocity_ins__CalculationMatrixRow__c> existingRows = [
                SELECT Id, Name, vlocity_ins__InputData__c, vlocity_ins__OutputData__c
                FROM vlocity_ins__CalculationMatrixRow__c 
                WHERE vlocity_ins__CalculationMatrixVersionId__c = :matrixVersionId
                ORDER BY Name ASC
            ];
            
            if (existingRows.isEmpty()) {
                throw new AuraHandledException('No existing rows found for the specified matrix version.');
            }
            
            // Get headers from first row to maintain structure
            Map<String, Object> firstRowMap = (Map<String, Object>) JSON.deserializeUntyped(existingRows[0].vlocity_ins__InputData__c);
            List<String> headers = new List<String>(firstRowMap.keySet());
            
            List<vlocity_ins__CalculationMatrixRow__c> rowsToUpdate = new List<vlocity_ins__CalculationMatrixRow__c>();
            
            // Process each updated record
            for (Map<String, Object> updatedRecord : updatedRecords) {
                // Handle rowNumber conversion safely
                Integer rowNumber = null;
                Object rowNumberObj = updatedRecord.get('rowNumber');
                
                if (rowNumberObj instanceof Integer) {
                    rowNumber = (Integer) rowNumberObj;
                } else if (rowNumberObj instanceof Decimal) {
                    rowNumber = ((Decimal) rowNumberObj).intValue();
                } else if (rowNumberObj instanceof String) {
                    try {
                        rowNumber = Integer.valueOf((String) rowNumberObj);
                    } catch (Exception e) {
                        System.debug('Error converting rowNumber string to integer: ' + e.getMessage());
                        continue; // Skip this record
                    }
                } else {
                    System.debug('Unknown rowNumber type: ' + rowNumberObj);
                    continue; // Skip this record
                }
                
                // Find corresponding matrix row (rowNumber is 1-based, array is 0-based)
                if (rowNumber != null && rowNumber > 0 && rowNumber <= existingRows.size()) {
                    vlocity_ins__CalculationMatrixRow__c rowToUpdate = existingRows[rowNumber - 1];
                    
                    // Rebuild InputData JSON with updated values
                    Map<String, Object> updatedInputData = new Map<String, Object>();
                    for (String header : headers) {
                        String fieldName = sanitizeFieldName(header);
                        Object fieldValue = updatedRecord.get(fieldName);
                        // Convert null/undefined to empty string
                        String stringValue = fieldValue != null ? String.valueOf(fieldValue) : '';
                        updatedInputData.put(header, stringValue);
                    }
                    
                    rowToUpdate.vlocity_ins__InputData__c = JSON.serialize(updatedInputData);
                    rowsToUpdate.add(rowToUpdate);
                    
                    System.debug('Prepared row for update: ' + rowToUpdate.Name + ' with data: ' + rowToUpdate.vlocity_ins__InputData__c);
                } else {
                    System.debug('Invalid rowNumber: ' + rowNumber + ' for record: ' + JSON.serialize(updatedRecord));
                }
            }
            
            if (!rowsToUpdate.isEmpty()) {
                update rowsToUpdate;
                System.debug('Successfully updated ' + rowsToUpdate.size() + ' records');
                return 'Successfully updated ' + rowsToUpdate.size() + ' records.';
            } else {
                System.debug('No valid records found for update');
                return 'No records were updated.';
            }
            
        } catch (Exception e) {
            System.debug('Error updating matrix data: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error updating matrix data: ' + e.getMessage());
        }
    }
    
    // Add method to create new matrix version from updated preview data
    @AuraEnabled
    public static String saveUpdatedPreviewAsVersion(String fileName, List<Map<String, Object>> updatedRecords, List<String> headers, String matrixName, String calculationMatrixId, List<Map<String, String>> columnConfigs) {
        try {
            if (updatedRecords == null || updatedRecords.isEmpty() || headers == null || headers.isEmpty()) {
                throw new AuraHandledException('Invalid data for saving updated preview.');
            }
            
            // Get or create calculation matrix
            String matrixId = calculationMatrixId;
            if (String.isBlank(matrixId)) {
                matrixId = getOrCreateCalculationMatrix(matrixName);
            }
            
            // Get the Calculation Matrix record
            vlocity_ins__CalculationMatrix__c calculationMatrix = [
                SELECT Id, Name
                FROM vlocity_ins__CalculationMatrix__c 
                WHERE Id = :matrixId 
                LIMIT 1
            ];
            
            // Get next version number
            Integer nextVersion = getNextAvailableVersionNumber(matrixId);
            String versionName = calculationMatrix.Name + ' V' + nextVersion;
            
            // Create new matrix version
            vlocity_ins__CalculationMatrixVersion__c matrixVersion = new vlocity_ins__CalculationMatrixVersion__c();
            matrixVersion.Name = versionName;
            matrixVersion.vlocity_ins__CalculationMatrixId__c = matrixId;
            matrixVersion.vlocity_ins__VersionNumber__c = nextVersion;
            matrixVersion.vlocity_ins__IsEnabled__c = false;
            matrixVersion.vlocity_ins__StartDateTime__c = System.now();
            matrixVersion.vlocity_ins__EndDateTime__c = System.now().addYears(1);
            matrixVersion.vlocity_ins__Priority__c = nextVersion; // Set priority to version number
            
            insert matrixVersion;
            
            // Create header records first using column configs
            List<vlocity_ins__CalculationMatrixRow__c> headerRows = new List<vlocity_ins__CalculationMatrixRow__c>();
            
            // Track which columns are inputs vs outputs based on configuration
            Map<String, String> headerTypes = new Map<String, String>();
            Map<String, String> dataTypes = new Map<String, String>();
            
            // If column configs are provided, use them; otherwise default all to Input/Text
            if (columnConfigs != null && !columnConfigs.isEmpty()) {
                for (Map<String, String> config : columnConfigs) {
                    String columnName = config.get('name');
                    headerTypes.put(columnName, config.get('headerType'));
                    dataTypes.put(columnName, config.get('dataType'));
                }
            } else {
                // Default all columns to Input and Text type
                for (String header : headers) {
                    headerTypes.put(header, 'Input');
                    dataTypes.put(header, 'Text');
                }
            }
            
            // Create a header record for each column
            Integer displayOrder = 1;
            for (String header : headers) {
                Map<String, Object> headerMetadata = new Map<String, Object>();
                headerMetadata.put('name', header);
                headerMetadata.put('headerType', headerTypes.containsKey(header) ? headerTypes.get(header) : 'Input');
                headerMetadata.put('displayOrder', displayOrder++);
                headerMetadata.put('dataType', dataTypes.containsKey(header) ? dataTypes.get(header) : 'Text');
                headerMetadata.put('columnKey', EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(header))).substring(0, 6));
                
                vlocity_ins__CalculationMatrixRow__c headerRow = new vlocity_ins__CalculationMatrixRow__c();
                headerRow.Name = 'Header';
                headerRow.vlocity_ins__CalculationMatrixVersionId__c = matrixVersion.Id;
                headerRow.vlocity_ins__InputData__c = JSON.serialize(headerMetadata);
                
                headerRows.add(headerRow);
            }
            
            insert headerRows;
            
            // Now create data rows from updated records
            List<vlocity_ins__CalculationMatrixRow__c> dataRows = new List<vlocity_ins__CalculationMatrixRow__c>();
            
            for (Map<String, Object> record : updatedRecords) {
                // Create maps for input and output data
                Map<String, Object> inputDataMap = new Map<String, Object>();
                Map<String, Object> outputDataMap = new Map<String, Object>();
                
                // Populate input and output maps based on header type
                for (String header : headers) {
                    String fieldName = sanitizeFieldName(header);
                    Object fieldValue = record.get(fieldName);
                    String value = fieldValue != null ? String.valueOf(fieldValue) : '';
                    
                    // If header is input type, add to inputDataMap, otherwise to outputDataMap
                    if (headerTypes.get(header) == 'Input') {
                        inputDataMap.put(header, value);
                    } else {
                        outputDataMap.put(header, value);
                    }
                }
                
                // Create matrix row record
                vlocity_ins__CalculationMatrixRow__c dataRow = new vlocity_ins__CalculationMatrixRow__c();
                dataRow.vlocity_ins__CalculationMatrixVersionId__c = matrixVersion.Id;
                
                // Generate unique hash for row name using input data
                String inputHash = EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(JSON.serialize(inputDataMap))));
                dataRow.Name = inputHash;
                
                // Serialize maps to JSON
                dataRow.vlocity_ins__InputData__c = JSON.serialize(inputDataMap);
                dataRow.vlocity_ins__OutputData__c = JSON.serialize(outputDataMap);
                
                // Set inherited date values from matrix version
                dataRow.vlocity_ins__StartDateTime__c = matrixVersion.vlocity_ins__StartDateTime__c;
                dataRow.vlocity_ins__EndDateTime__c = matrixVersion.vlocity_ins__EndDateTime__c;
                
                dataRows.add(dataRow);
            }
            
            if (!dataRows.isEmpty()) {
                insert dataRows;
            }
            
            return matrixVersion.Id;
            
        } catch (Exception e) {
            System.debug('Error saving updated preview: ' + e.getMessage());
            throw new AuraHandledException('Error saving updated preview: ' + e.getMessage());
        }
    }
    
    /**
     * @description Enable the selected matrix version and disable all others for the same matrix.
     * @param matrixVersionId ID of the CalculationMatrixVersion to enable
     * @return Boolean Success status
     */
    @AuraEnabled
    public static Boolean enableOnlySelectedMatrixVersion(String matrixVersionId) {
        try {
            if (String.isBlank(matrixVersionId)) {
                throw new AuraHandledException('Matrix Version Id is required.');
            }
            
            // Get the selected version
            vlocity_ins__CalculationMatrixVersion__c selectedVersion = [
                SELECT Id, vlocity_ins__CalculationMatrixId__c, vlocity_ins__IsEnabled__c
                FROM vlocity_ins__CalculationMatrixVersion__c
                WHERE Id = :matrixVersionId
                LIMIT 1
            ];
            
            // If already enabled, nothing to do
            if (selectedVersion.vlocity_ins__IsEnabled__c) {
                return true;
            }
            
            // Just enable the selected version - Vlocity will handle disabling others automatically
            // This avoids triggering the validation rule that prevents disabling
            selectedVersion.vlocity_ins__IsEnabled__c = true;
            update selectedVersion;
            
            return true;
        } catch (Exception e) {
            throw new AuraHandledException('Error enabling matrix version: ' + e.getMessage());
        }
    }

    /**
     * @description Search CSV data across all records in a matrix version
     * @param matrixVersionId ID of the CalculationMatrixVersion
     * @param searchTerm Search term to filter data
     * @param pageNumber Current page number (1-based)
     * @param pageSize Number of records per page
     * @return CsvDataResponse Wrapper containing filtered data and pagination info
     */
    @AuraEnabled(cacheable=false)
    public static CsvDataResponse searchMatrixCsvData(String matrixVersionId, String searchTerm, Integer pageNumber, Integer pageSize) {
        try {
            if (pageSize == null || pageSize <= 0) {
                pageSize = DEFAULT_PAGE_SIZE;
            }
            
            if (pageNumber == null || pageNumber <= 0) {
                pageNumber = 1;
            }
            
            // Get the matrix version record
            vlocity_ins__CalculationMatrixVersion__c matrixVersion = [
                SELECT Id, Name, vlocity_ins__VersionNumber__c, vlocity_ins__CalculationMatrixId__c,
                       vlocity_ins__IsEnabled__c, vlocity_ins__StartDateTime__c, vlocity_ins__EndDateTime__c
                FROM vlocity_ins__CalculationMatrixVersion__c 
                WHERE Id = :matrixVersionId 
                LIMIT 1
            ];
            
            // Get CSV data from CalculationMatrixRow records
            List<vlocity_ins__CalculationMatrixRow__c> allRows = [
                SELECT Id, Name, vlocity_ins__InputData__c, vlocity_ins__OutputData__c
                FROM vlocity_ins__CalculationMatrixRow__c 
                WHERE vlocity_ins__CalculationMatrixVersionId__c = :matrixVersionId
                ORDER BY Name ASC
            ];
            
            // Parse stored CSV data from rows
            List<List<String>> parsedCsv = reconstructCsvFromRows(allRows);
            
            if (parsedCsv.isEmpty()) {
                throw new AuraHandledException('No data found in calculation matrix version.');
            }
            
            // Extract headers and data
            List<String> headers = parsedCsv[0];
            List<List<String>> allDataRows = new List<List<String>>();
            
            // Skip header row and apply search filter
            for (Integer i = 1; i < parsedCsv.size(); i++) {
                List<String> row = parsedCsv[i];
                
                // If no search term, include all rows
                if (String.isBlank(searchTerm)) {
                    allDataRows.add(row);
                } else {
                    // Check if any field in the row contains the search term (case-insensitive)
                    Boolean matchFound = false;
                    String lowerSearchTerm = searchTerm.toLowerCase();
                    
                    for (String cellValue : row) {
                        if (String.isNotBlank(cellValue) && cellValue.toLowerCase().contains(lowerSearchTerm)) {
                            matchFound = true;
                            break;
                        }
                    }
                    
                    if (matchFound) {
                        allDataRows.add(row);
                    }
                }
            }
            
            // Calculate pagination on filtered results
            Integer totalRecords = allDataRows.size();
            Integer totalPages = totalRecords > 0 ? (Integer) Math.ceil((Decimal) totalRecords / pageSize) : 0;
            Integer startIndex = (pageNumber - 1) * pageSize;
            Integer endIndex = Math.min(startIndex + pageSize, totalRecords);
            
            // Get current page data from filtered results
            List<List<String>> pageData = new List<List<String>>();
            for (Integer i = startIndex; i < endIndex; i++) {
                if (i < allDataRows.size()) {
                    pageData.add(allDataRows[i]);
                }
            }
            
            // Convert to map format for Lightning Data Table
            List<Map<String, Object>> records = convertToRecords(headers, pageData, startIndex);
            
            // Create response
            CsvDataResponse response = new CsvDataResponse();
            response.records = records;
            response.headers = headers;
            response.totalRecords = totalRecords;
            response.currentPage = pageNumber;
            response.pageSize = pageSize;
            response.totalPages = totalPages;
            response.hasNext = pageNumber < totalPages;
            response.hasPrevious = pageNumber > 1;
            response.fileName = matrixVersion.Name + '_v' + matrixVersion.vlocity_ins__VersionNumber__c + '.csv';
            response.matrixVersionId = matrixVersionId;
            response.isEnabled = matrixVersion.vlocity_ins__IsEnabled__c;
            response.searchTerm = searchTerm; // Include search term in response
            
            return response;
            
        } catch (Exception e) {
            System.debug('Error in searchMatrixCsvData: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error searching matrix CSV data: ' + e.getMessage());
        }
    }
}