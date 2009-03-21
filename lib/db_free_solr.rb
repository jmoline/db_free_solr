module ActsAsSolr #:nodoc:
  module ClassMethods
    def multi_solr_search(query, options = {})
      include CommonMethods
      models = "AND (#{solr_configuration[:type_field]}:#{self.name}"
      options[:models].each{|m| models << " OR type_t:"+m.to_s} if options[:models].is_a?(Array)
      options.update(:results_format => :objects) unless options[:results_format]
      data = parse_query(query, options, models<<")")
      result = []
      if data
        docs = data.docs
        return SearchResults.new(:docs => [], :total => 0) if data.total == 0

        if options[:results_format] == :objects
          #adding this line (and commenting out the next) is the only change to this method
          docs.each{|doc| k = doc.fetch('id').to_s.split(':'); result << SolrModel.new(doc[:type_t].to_s, doc)}
          #docs.each{|doc| k = doc.fetch('id').to_s.split(':'); result << k[0].constantize.find_by_id(k[1])}
        elsif options[:results_format] == :ids
          docs.each{|doc| result << {"id"=>doc.values.pop.to_s}}
        end
        SearchResults.new :docs => result, :total => data.total   
      end
    end
  end
  
  module ParserMethods
    def parse_query(query=nil, options={}, models=nil)
      valid_options = [:offset, :limit, :facets, :models, :results_format, :order, :scores, :operator]
      query_options = {}
      return if query.nil?
      raise "Invalid parameters: #{(options.keys - valid_options).join(',')}" unless (options.keys - valid_options).empty?
      begin
        Deprecation.validate_query(options)
        query_options[:start] = options[:offset]
        query_options[:rows] = options[:limit]
        query_options[:operator] = options[:operator]
        
        # first steps on the facet parameter processing
        if options[:facets]
          query_options[:facets] = {}
          query_options[:facets][:limit] = -1  # TODO: make this configurable
          query_options[:facets][:sort] = :count if options[:facets][:sort]
          query_options[:facets][:mincount] = 0
          query_options[:facets][:mincount] = 1 if options[:facets][:zeros] == false
          query_options[:facets][:fields] = options[:facets][:fields].collect{|k| "#{k}_facet"} if options[:facets][:fields]
          query_options[:filter_queries] = replace_types(options[:facets][:browse].collect{|k| "#{k.sub!(/ *: */,"_facet:")}"}) if options[:facets][:browse]
          query_options[:facets][:queries] = replace_types(options[:facets][:query].collect{|k| "#{k.sub!(/ *: */,"_t:")}"}) if options[:facets][:query]
        end
        
        if models.nil?
          # TODO: use a filter query for type, allowing Solr to cache it individually
          models = "AND #{solr_configuration[:type_field]}:#{self.name}"
          field_list = solr_configuration[:primary_key_field]
        else
          field_list = "id"
        end
        
        #commenting out this line of code is the only change to this method
        #it's been removed because the default field_list (in the called method) is '*'
        #but, unless this line is commented out, it will only return the primary key
        #query_options[:field_list] = [field_list, 'score']
        query = "(#{query.gsub(/ *: */,"_t:")}) #{models}"
        order = options[:order].split(/\s*,\s*/).collect{|e| e.gsub(/\s+/,'_t ')  }.join(',') if options[:order] 
        query_options[:query] = replace_types([query])[0] # TODO adjust replace_types to work with String or Array  

        if options[:order]
          # TODO: set the sort parameter instead of the old ;order. style.
          query_options[:query] << ';' << replace_types([order], false)[0]
        end
               
        ActsAsSolr::Post.execute(Solr::Request::Standard.new(query_options))
      rescue
        raise "There was a problem executing your search: #{$!}"
      end            
    end
    
    def parse_results(solr_data, options = {})
      include CommonMethods
      results = {
        :docs => [],
        :total => 0
      }
      configuration = {
        :format => :objects
      }
      results.update(:facets => {'facet_fields' => []}) if options[:facets]
      return SearchResults.new(results) if solr_data.total == 0
      
      configuration.update(options) if options.is_a?(Hash)

      #commented out the next 3 lines
      #ids = solr_data.docs.collect {|doc| doc["#{solr_configuration[:primary_key_field]}"]}.flatten
      #conditions = [ "#{self.table_name}.#{primary_key} in (?)", ids ]
      #result = configuration[:format] == :objects ? reorder(self.find(:all, :conditions => conditions), ids) : ids
      #added the next two lines
      result = []
      configuration[:format] == :objects ? solr_data.docs.each {|doc| result << SolrModel.new(doc[:type_t].to_s, doc)} : solr_data.docs.each {|doc| result << {"id"=>doc.values.pop.to_s}}
      add_scores(result, solr_data) if configuration[:format] == :objects && options[:scores]
      
      results.update(:facets => solr_data.data['facet_counts']) if options[:facets]
      results.update({:docs => result, :total => solr_data.total, :max_score => solr_data.max_score})
      SearchResults.new(results)
    end
    
  end
  
  module CommonMethods

    # Converts field types into Solr types
    def get_solr_field_type(field_type)
      if field_type.is_a?(Symbol)
        case field_type
          when :float:          return "f"
          when :integer:        return "i"
          when :boolean:        return "b"
          when :string:         return "s"
          when :date:           return "d"
          when :range_float:    return "rf"
          when :range_integer:  return "ri"
          when :facet:          return "facet"
          when :text:           return "t"
            
          when :float_so:          return "sf"
          when :integer_so:        return "si"
          when :boolean_so:        return "sb"
          when :string_so:         return "ss"
          when :date_so:           return "sd"
          when :text_so:           return "st"

          when :float_io:          return "if"
          when :integer_io:        return "ii"
          when :boolean_io:        return "ib"
          when :string_io:         return "is"
          when :date_io:           return "id"
          when :text_io:           return "it"
          
        else
          raise "Unknown field_type symbol: #{field_type}"
        end
      elsif field_type.is_a?(String)
        return field_type
      else
        raise "Unknown field_type class: #{field_type.class}: #{field_type}"
      end
    end
    
    # Sets a default value when value being set is nil.
    def set_value_if_nil(field_type)
      case field_type
        when "b", :boolean, :boolean_so, :boolean_io:                         return "false"
        when "s", :string, :string_so, :string_io:                            return ""
        when "t", :text, :text_so, :text_io:                                  return ""
        when "d", :date, :date_so, :date_io:                                  return ""
        when "f", "rf", :float, :float_so, :float_io, :range_float:           return 0.00
        when "i", "ri", :integer, :integer_so, :integer_io, :range_integer:   return 0
      else
        return ""
      end
    end
  end
  
  class SolrModel
    include Enumerable
    
   attr_accessor :class_name

   def initialize(class_name, attributes = nil)
     @class_name = class_name

     @attributes = {}

     attributes.each do |attribute,value|
       @attributes[clean_attribute_name(attribute).to_sym] = value
     end
   end

   def method_missing(method_id, *args)
     raise "There's no #{method_id} method... remember this is not an AR instance!!" unless @attributes.include?(method_id)

     @attributes[method_id]
   end
   
   def each(&block)
   end
   
   def ===(other)
     other.class.to_s == class_name
   end
   
   def type
     @attributes[:type]
   end

   private

     def clean_attribute_name(attribute)
       attribute = attribute.to_s
       attribute[0..((attribute.rindex('_') || 0) -1)]
     end

  end
  
end