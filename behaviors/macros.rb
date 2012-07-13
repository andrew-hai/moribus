module Core
  module Behaviors
    # Declares a set of helper methods for more efficient use of aggregated
    # and tracked models.
    module Macros
      # Specify a set of attributes to be 'shared' with the associated
      # object. Define a before_save callback that sets values of designated
      # attributes in the associated object as they are in self.
      #
      # Purpose: the Customer has a customer_status, and it is defined via
      # state_machine. This sets a special behavior and set of scopes that rely
      # on the Customer's 'customer_status' column. To keep track of status
      # changes, the CustomerInfo tracked model, associated with the customer
      # also has a 'customer_status' column. That will allow status changes
      # to be tracked via the tracked behavior of CustomerInfo.
      def share(*args)
        options = args.extract_options!
        association_name = options[:with] or raise ArgumentError.new(":with option should be provided")
        attributes = args.dup

        before_save do
          unless (associated = send(association_name)).nil?
            attributes.each{ |attr| associated.send(:"#{attr}=", send(attr)) }
          end
        end
      end
      private :share

      # For each of the passed arguments, which may either be method or
      # association names, define its delegation to the specified association.
      # If it responds to the effective reader, delegate to it.
      # If the subject of delegation is a method name, delegate both reader and writer.
      # If the subject of delegation is an association name, and the association
      # was defined via the +has_aggregated+ helper method, include the
      # association's delegation module, effectively using attribute readers,
      # and write the associated object. See the example below for a more
      # expressive explanation:
      #
      #   class CustomerAttributes < ActiveRecord::Base
      #     # has date_of_birth and is_military attributes
      #     acts_as_aggregated
      #   end
      #   
      #   class PersonName < ActiveRecord::Base
      #     # has first_name and last_name attributes
      #     acts_as_aggregated
      #   end
      #   
      #   class CustomerInfo < ActiveRecord::Base
      #     belongs_to :customer, :inverse_of => :customer_info
      #   
      #     has_aggregated :customer_attributes
      #     has_aggregated :person_name
      #     acts_as_tracked
      #   end
      #   
      #   class Customer < ActiveRecord::Base
      #     has_one_current :customer_info, :inverse_of => :customer
      #   
      #     delegate_associated :customer_attributes, :person_name, :to => :customer_info
      #   end
      #   
      #   customer = Customer.new
      #   info = customer.effective_customer_info
      #   
      #   # note here we're skipping info.person_name building for readers and writers.
      #   info.first_name # => nil
      #   info.first_name = 'John'
      #   info.date_of_birth = Date.today
      #   
      #   customer.first_name # => 'John'
      #   customer.is_military = true
      #   customer.is_military == info.is_military # => true
      #   info.is_military == info.customer_attributes.is_military # => true
      def delegate_associated(*args)
        options = args.extract_options!
        name = options[:to] or raise ArgumentError.new(":to option should be provided")
        include Extensions::DelegateAssociated unless self < Extensions::DelegateAssociated
        effective_name = "effective_#{name}".in?(instance_methods(false)) ? "effective_#{name}" : name
        klass = reflect_on_association(name).klass

        args.each do |association_name|
          delegate(association_name, :to => effective_name)

          if (association_reflection = klass.reflect_on_association(association_name)).present?
            self.classes_delegating_to += [association_reflection.klass]
            if association_reflection.respond_to?(:delegated_attribute_methods)
              delegate("effective_#{association_name}", :to => effective_name)
              include association_reflection.delegated_attribute_methods
            end
          else
            delegate :"#{association_name}=", :to => effective_name
          end
        end
      end

      # Define a +has_one+ association with `{:is_current => true}` value for
      # :conditions clause. Also define acceptance of nested attributes for
      # association and effective reader.
      def has_one_current(name, options = {})
        reflection = has_one name, options.merge(:conditions => {:is_current => true}).reverse_merge(:order => 'id DESC')
        reflection.options[:is_current] = true
        accepts_nested_attributes_for name
        define_effective_reader_for name
        alias_association :"current_#{name}", name
        reflection
      end
      private :has_one_current

      # Defines +belongs_to+ association, acceptance of nested attributes for it,
      # defines effective reader for associated object, and extends association
      # by special aggregated functionality (attribute delegation. See
      # Extensions::HasAggregatedExtension)
      def has_aggregated(name, options = {})
        reflection = belongs_to(name, options)
        reflection.options[:aggregated] = true
        accepts_nested_attributes_for name
        define_effective_reader_for name
        extend_has_aggregated_reflection(reflection)
        reflection
      end
      private :has_aggregated

      # Record +attribute+ change date in +change_date+ field. For example:
      #
      # class Foo
      #   ...
      #   track_attr_change_at :bar, :bar_changed_at
      #   ...
      # end
      #
      # When a Foo object gets a new :bar attribute value the current time will
      # be set in :bar_changed_at.
      def tracks_attr_change_date(attribute, change_date)
        define_method("track_#{attribute}_change_date") {
          if changed?
            changed_at = nil
            changed_at = Time.zone.now if changed.include? attribute.to_s
            self.send("#{change_date}=", changed_at)
          end
        }

        before_save "track_#{attribute}_change_date"
      end
      private :tracks_attr_change_date

      # Record status +attribute+ change date in +change_date+
      # (default - :status_changed_at) field.
      # It's a shortcut to +track_attr_change_date+ method. For example:
      #
      # class ApplicationInfo
      #   ...
      #   track_status_changed_at :application_status_id
      #   ...
      # end
      #
      # When :application_status_id gets a new value the current time will be
      # set in :status_changed_at.
      def tracks_status_change_date(attribute, change_date = :status_changed_at)
        tracks_attr_change_date(attribute, change_date)
      end
      private :tracks_status_change_date

      # Declare a reader that will build associated object if it does not exist.
      # We can actually extend an association's readers like:
      #
      #   def reader
      #     super || build
      #   end
      #
      # But this corrupts the has_one association's create_other method
      # (and I failed to dig out why --a.kuzko). Also, this will result in
      # failing `it { should validate_presence_of :other }` specs, since
      # auto-building will prevent `nil` values that are used by specs.
      def define_effective_reader_for(name)
        class_eval <<-eoruby, __FILE__, __LINE__
          def effective_#{name}; #{name} || build_#{name}; end
        eoruby
      end
      private :define_effective_reader_for

      # Create a writer method to remove unwanted characters from string input
      # (or anything that supports gsub). You can provide custom filters.
      # The filter defaults to a numeric filter (including the decimal point).
      #
      # @param [Symbol] attribute
      # @param [Regexp] filter
      def filters_input_on(attribute, filter = /[^\d\.]/)
        class_eval <<-eoruby, __FILE__, __LINE__
          def #{attribute}=(value)
            super value.respond_to?(:gsub) ? value.gsub(Regexp.new('#{filter.to_s}'), '') : value
          end
        eoruby
      end
      private :filters_input_on
    end
  end
end
